library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- uart_tx's output wired directly into uart_rx's input (physical
-- loopback). Exercises both modules together exactly as they'll be used
-- in top.vhd, plus a few back-to-back bytes to stress state transitions.
entity tb_uart_loopback is
end entity tb_uart_loopback;

architecture sim of tb_uart_loopback is
  constant CLK_PERIOD  : time := 10 ns;
  constant CLK_FREQ_HZ : natural := 27_000_000;
  constant BAUD_RATE   : natural := 1_500_000;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_start : std_logic := '0';
  signal tx_busy  : std_logic;
  signal serial   : std_logic;

  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;

  -- Concurrent collector: captures every received byte as it arrives so
  -- back-to-back transmissions (no gap for the stim process to poll
  -- between each one) can't have their data_valid pulse missed by a
  -- sequential "send then check" testbench structure.
  type rx_log_t is array (0 to 15) of std_logic_vector(7 downto 0);
  signal rx_log       : rx_log_t := (others => (others => '0'));
  signal rx_log_count : natural range 0 to 16 := 0;
begin

  collector : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        rx_log_count <= 0;
      elsif rx_valid = '1' and rx_log_count < 16 then
        rx_log(rx_log_count) <= rx_data;
        rx_log_count <= rx_log_count + 1;
      end if;
    end if;
  end process;

  tx : entity work.uart_tx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk, rst => rst,
      data_in => tx_data, tx_start => tx_start, busy => tx_busy,
      tx => serial
    );

  rx : entity work.uart_rx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD_RATE => BAUD_RATE)
    port map (
      clk => clk, rst => rst,
      rx => serial,
      data_out => rx_data, data_valid => rx_valid
    );

  clk_gen : process
  begin
    while not sim_done loop
      clk <= '0'; wait for CLK_PERIOD / 2;
      clk <= '1'; wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process;

  stim : process
    variable rx_seen  : boolean;
    variable rx_value : std_logic_vector(7 downto 0);
    variable base      : natural;

    procedure send_byte(b : natural) is
    begin
      wait until rising_edge(clk);
      tx_data <= std_logic_vector(to_unsigned(b, 8));
      tx_start <= '1';
      wait until rising_edge(clk);
      tx_start <= '0';
    end procedure;

    procedure expect_byte(expected : natural; msg : string) is
      variable cycles : natural := 0;
    begin
      rx_seen := false;
      while not rx_seen and cycles < 500 loop
        wait until rising_edge(clk);
        if rx_valid = '1' then
          rx_seen := true;
          rx_value := rx_data;
        end if;
        cycles := cycles + 1;
      end loop;
      if not rx_seen then
        report "FAIL: " & msg & " (timed out waiting for data_valid)" severity error;
        errors <= errors + 1;
      elsif to_integer(unsigned(rx_value)) /= expected then
        report "FAIL: " & msg & " got=" & integer'image(to_integer(unsigned(rx_value))) &
               " exp=" & integer'image(expected) severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    ------------------------------------------------------------------
    -- Single bytes, waiting for tx idle between each.
    ------------------------------------------------------------------
    for b in 0 to 4 loop
      send_byte((b * 53 + 7) mod 256);
      expect_byte((b * 53 + 7) mod 256, "single byte #" & integer'image(b));
      wait until tx_busy = '0';
      wait until rising_edge(clk);
    end loop;

    ------------------------------------------------------------------
    -- Back-to-back bytes: kick off the next tx_start as soon as tx goes
    -- idle (no extra idle gap), stressing S_STOP -> S_IDLE -> S_START.
    ------------------------------------------------------------------
    base := rx_log_count;

    send_byte(16#AA#);
    wait until tx_busy = '0';
    send_byte(16#55#);
    wait until tx_busy = '0';
    send_byte(16#F0#);
    wait until tx_busy = '0';
    for i in 0 to 400 loop
      wait until rising_edge(clk);
    end loop;

    if rx_log_count /= base + 3 then
      report "FAIL: back-to-back: expected 3 bytes collected, got " &
             integer'image(rx_log_count - base) severity error;
      errors <= errors + 1;
    else
      report "PASS: back-to-back: 3 bytes collected" severity note;
    end if;
    if rx_log_count >= base + 1 then
      if to_integer(unsigned(rx_log(base))) = 16#AA# then
        report "PASS: back-to-back #1" severity note;
      else
        report "FAIL: back-to-back #1 got=" & integer'image(to_integer(unsigned(rx_log(base)))) severity error;
        errors <= errors + 1;
      end if;
    end if;
    if rx_log_count >= base + 2 then
      if to_integer(unsigned(rx_log(base + 1))) = 16#55# then
        report "PASS: back-to-back #2" severity note;
      else
        report "FAIL: back-to-back #2 got=" & integer'image(to_integer(unsigned(rx_log(base + 1)))) severity error;
        errors <= errors + 1;
      end if;
    end if;
    if rx_log_count >= base + 3 then
      if to_integer(unsigned(rx_log(base + 2))) = 16#F0# then
        report "PASS: back-to-back #3" severity note;
      else
        report "FAIL: back-to-back #3 got=" & integer'image(to_integer(unsigned(rx_log(base + 2)))) severity error;
        errors <= errors + 1;
      end if;
    end if;

    ------------------------------------------------------------------
    report "tb_uart_loopback: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_uart_loopback FAILED" severity failure;
    else
      report "tb_uart_loopback PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
