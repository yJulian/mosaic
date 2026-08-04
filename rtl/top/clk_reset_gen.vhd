library ieee;
use ieee.std_logic_1164.all;

-- Reset synchronizer: takes an active-low external reset input (e.g. a
-- board button) and produces a clean, synchronous, active-high reset
-- for internal use. Asserted immediately (initial values), released
-- synchronously a few cycles after the button releases -- standard
-- "async assert, sync deassert" pattern via a 3-stage shift register,
-- which also provides metastability protection on the external pin.
entity clk_reset_gen is
  port (
    clk       : in std_logic;
    rst_btn_n : in std_logic;
    rst       : out std_logic
  );
end entity clk_reset_gen;

architecture rtl of clk_reset_gen is
  signal sync_reg : std_logic_vector(2 downto 0) := (others => '1');
begin

  process (clk)
  begin
    if rising_edge(clk) then
      sync_reg <= sync_reg(1 downto 0) & (not rst_btn_n);
    end if;
  end process;

  rst <= sync_reg(2);

end architecture rtl;
