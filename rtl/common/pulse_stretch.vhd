library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Stretches a short/single-cycle trigger into a fixed-duration output level,
-- long enough for a human to see on an LED. Retriggerable: any trigger seen
-- while already counting down just restarts the countdown, so back-to-back
-- events read as one continuous glow rather than flickering. Level triggers
-- longer than CYCLES pass through unchanged (the countdown keeps reloading
-- every cycle trigger is high).
entity pulse_stretch is
  generic (
    CYCLES : natural := 5_400_000 -- 200ms at 27MHz
  );
  port (
    clk     : in  std_logic;
    rst     : in  std_logic;
    trigger : in  std_logic;
    stretched : out std_logic
  );
end entity pulse_stretch;

architecture rtl of pulse_stretch is
  constant CTR_MAX : natural := CYCLES - 1;
  signal counter : natural range 0 to CTR_MAX := 0;
begin
  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        counter <= 0;
      elsif trigger = '1' then
        counter <= CTR_MAX;
      elsif counter > 0 then
        counter <= counter - 1;
      end if;
    end if;
  end process;

  stretched <= '1' when (counter > 0 or trigger = '1') else '0';

end architecture rtl;
