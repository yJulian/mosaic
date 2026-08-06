library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Minimal bring-up smoke test: a heartbeat LED and nothing else. Build
-- it with scripts/build.sh and program it BEFORE attempting the full
-- top.vhd design (see docs/bringup.md) -- it isolates "is the clock
-- pin, LED pin, and programming path right" from every other question
-- the full design would otherwise raise at the same time.
entity blinky is
  port (
    clk   : in std_logic;
    led_n : out std_logic
  );
end entity blinky;

architecture rtl of blinky is
  signal ctr : unsigned(23 downto 0) := (others => '0');
begin
  process (clk)
  begin
    if rising_edge(clk) then
      ctr <= ctr + 1;
    end if;
  end process;

  led_n <= not ctr(23); -- ~1.6Hz at 27MHz; active-low LED assumed, see docs/bringup.md

end architecture rtl;
