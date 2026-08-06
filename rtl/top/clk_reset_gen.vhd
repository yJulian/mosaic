library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Internal power-on reset generator: holds `rst` asserted for a handful
-- of cycles after configuration, then deasserts permanently. No
-- external pin.
--
-- This used to take an active-low external reset button on rst_btn_n
-- (Tang Nano 20K pin 88, shared with the chip's MODE0 boot-mode strap
-- and Sipeed's "KEY1" button). Hardware bring-up found that pin reads
-- permanently low on the real board -- via the UART bisection tests in
-- docs/bringup.md, confirmed with a diagnostic bitstream that read the
-- pin back over the link -- which held `rst` asserted forever and
-- silently killed the entire design (everything downstream of `rst`
-- stays in its reset state indefinitely). Whether that's a fault on
-- this specific board or this MODE-shared pin not behaving as a plain
-- GPIO after configuration on this device wasn't pinned down further;
-- either way, this design's registers are already fully initial-valued
-- for simulation, so a plain POR pulse is enough and doesn't depend on
-- any external pin.
entity clk_reset_gen is
  port (
    clk : in std_logic;
    rst : out std_logic
  );
end entity clk_reset_gen;

architecture rtl of clk_reset_gen is
  constant POR_CYCLES : natural := 15;
  signal por_count : unsigned(3 downto 0) := (others => '0');
  signal por_done  : std_logic := '0';
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if por_done = '0' then
        if por_count = POR_CYCLES then
          por_done <= '1';
        else
          por_count <= por_count + 1;
        end if;
      end if;
    end if;
  end process;

  rst <= not por_done;

end architecture rtl;
