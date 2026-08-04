library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_memmap.all;

-- Named instantiation of bram_sdp sized for the full scratchpad memory
-- map (docs/memory_map.md / pkg_memmap.vhd). Region decoding itself is
-- the caller's responsibility (cmd_processor for host access, the
-- feeder/drainer for burst copies into their staging registers) -- this
-- module is just raw addressable memory.
entity scratchpad is
  port (
    clk : in std_logic;

    w_addr : in unsigned(ADDR_WIDTH - 1 downto 0);
    w_data : in std_logic_vector(7 downto 0);
    w_en   : in std_logic;

    r_addr : in unsigned(ADDR_WIDTH - 1 downto 0);
    r_data : out std_logic_vector(7 downto 0)
  );
end entity scratchpad;

architecture rtl of scratchpad is
begin

  mem : entity work.bram_sdp
    generic map (
      ADDR_WIDTH => ADDR_WIDTH,
      DATA_WIDTH => 8,
      DEPTH      => SCRATCHPAD_SIZE
    )
    port map (
      clk => clk,
      w_addr => w_addr, w_data => w_data, w_en => w_en,
      r_addr => r_addr, r_data => r_data
    );

end architecture rtl;
