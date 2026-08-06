library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Bring-up debug aid, not part of the normal design (see docs/bringup.md
-- "UART link only" step and uart_wire_test.vhd). Bisection test #2 of 2:
-- exercises the real uart_rx/uart_tx FSMs (baud generation, framing) on
-- real silicon, but skips everything above them (fifos, cmd_processor,
-- protocol framing/CRC). A byte sent by the host should come back
-- unchanged one RTT later. If test #1 (raw wire) echoed fine but this
-- one doesn't, the bug is in uart_rx.vhd/uart_tx.vhd's clock-domain/baud
-- logic specifically -- not the pins, not cmd_processor.
entity uart_echo_test is
  generic (
    CLK_FREQ_HZ : natural := 27_000_000;
    BAUD_RATE   : natural := 1_500_000
  );
  port (
    clk : in std_logic;

    uart_rx_pin : in std_logic;
    uart_tx_pin : out std_logic;

    led_n : out std_logic_vector(5 downto 0)
  );
end entity uart_echo_test;

architecture rtl of uart_echo_test is
  signal rst : std_logic;

  signal rx_data_out   : std_logic_vector(7 downto 0);
  signal rx_data_valid : std_logic;
  signal tx_data_in    : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_start      : std_logic := '0';
  signal tx_busy       : std_logic;
  signal pending       : std_logic := '0';

  signal heartbeat_ctr : unsigned(23 downto 0) := (others => '0');
  signal rx_count      : unsigned(7 downto 0) := (others => '0');
begin

  reset_gen : entity work.clk_reset_gen
    port map (clk => clk, rst => rst);

  rx : entity work.uart_rx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk, rst => rst,
      rx => uart_rx_pin,
      data_out => rx_data_out, data_valid => rx_data_valid
    );

  tx : entity work.uart_tx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk, rst => rst,
      data_in => tx_data_in, tx_start => tx_start, busy => tx_busy,
      tx => uart_tx_pin
    );

  -- Latch each received byte and re-send it as soon as the transmitter
  -- is free. No FIFO: a byte arriving while one is already pending
  -- would be dropped, but the ping-style single-byte tests this is for
  -- never do that.
  echo_proc : process (clk)
  begin
    if rising_edge(clk) then
      tx_start <= '0';
      if rst = '1' then
        pending <= '0';
        rx_count <= (others => '0');
      else
        if rx_data_valid = '1' then
          tx_data_in <= rx_data_out;
          pending <= '1';
          rx_count <= rx_count + 1;
        elsif pending = '1' and tx_busy = '0' then
          tx_start <= '1';
          pending <= '0';
        end if;
      end if;
    end if;
  end process;

  -- led0: ~1.6Hz heartbeat (clock/bitstream alive). led1: toggles per
  -- received byte, so byte-arrival is visible even without a host tool.
  process (clk)
  begin
    if rising_edge(clk) then
      heartbeat_ctr <= heartbeat_ctr + 1;
    end if;
  end process;

  led_n <= not (heartbeat_ctr(23) & rx_count(0) & "0000");

end architecture rtl;
