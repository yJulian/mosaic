library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Generic simple-dual-port BRAM: one write port, one independent read
-- port, both addressed every cycle, registered (1-cycle latency) read.
-- This exact idiom (array read/written inside a single clocked process,
-- registered read) is confirmed to infer Gowin DPB cells via synth_gowin
-- (see docs/architecture.md toolchain notes) rather than falling back to
-- LUTRAM or flip-flop arrays -- re-check with a synthesis cell-count
-- report any time this pattern is modified.
entity bram_sdp is
  generic (
    ADDR_WIDTH : natural := 16;
    DATA_WIDTH : natural := 8;
    DEPTH      : natural := 65536
  );
  port (
    clk : in std_logic;

    w_addr : in unsigned(ADDR_WIDTH - 1 downto 0);
    w_data : in std_logic_vector(DATA_WIDTH - 1 downto 0);
    w_en   : in std_logic;

    r_addr : in unsigned(ADDR_WIDTH - 1 downto 0);
    r_data : out std_logic_vector(DATA_WIDTH - 1 downto 0)
  );
end entity bram_sdp;

architecture rtl of bram_sdp is
  type ram_t is array (0 to DEPTH - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal mem : ram_t := (others => (others => '0'));
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if w_en = '1' then
        mem(to_integer(w_addr)) <= w_data;
      end if;
      r_data <= mem(to_integer(r_addr));
    end if;
  end process;

end architecture rtl;
