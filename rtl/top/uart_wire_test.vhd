library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Bring-up debug aid, not part of the normal design (see docs/bringup.md
-- "UART link only" step). Bisection test #1 of 2: a *combinational*
-- passthrough from uart_rx_pin straight to uart_tx_pin, with zero UART
-- framing/baud logic in between. If a host sending bytes on TX doesn't
-- see them come back on RX with this loaded, the bug is below the
-- uart_rx/uart_tx FSMs entirely -- wrong pins, wrong IO_TYPE/bank
-- voltage, bitstream not actually loaded/running, or the host is on the
-- wrong COM port -- not in this project's UART logic. If it *does* echo,
-- move on to uart_echo_test.vhd (bisection test #2) to exercise the real
-- uart_rx/uart_tx FSMs' baud generation on real silicon.
entity uart_wire_test is
  port (
    clk : in std_logic;

    uart_rx_pin : in std_logic;
    uart_tx_pin : out std_logic;

    led_n : out std_logic_vector(5 downto 0)
  );
end entity uart_wire_test;

architecture rtl of uart_wire_test is
  signal heartbeat_ctr : unsigned(23 downto 0) := (others => '0');
begin

  -- The test: raw wire, no clock domain involved at all.
  uart_tx_pin <= uart_rx_pin;

  -- led0: ~1.6Hz heartbeat, proves clock + bitstream are alive
  -- independent of the UART test above (same as top.vhd's heartbeat).
  process (clk)
  begin
    if rising_edge(clk) then
      heartbeat_ctr <= heartbeat_ctr + 1;
    end if;
  end process;

  led_n <= not (heartbeat_ctr(23) & "00000");

end architecture rtl;
