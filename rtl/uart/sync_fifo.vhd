library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Generic single-clock-domain FIFO (count-based, works for any DEPTH, not
-- just powers of two). Used for UART RX/TX byte buffering. Expected to
-- synthesize as distributed LUTRAM/registers, not BSRAM, given the small
-- depths used here -- re-check with a cell-count report if DEPTH grows.
-- rd_data is registered: valid the cycle *after* rd_en is asserted (with
-- empty='0'), standard synchronous-read-port FIFO convention.
entity sync_fifo is
  generic (
    WIDTH : natural := 8;
    DEPTH : natural := 16
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    wr_en   : in std_logic;
    wr_data : in std_logic_vector(WIDTH - 1 downto 0);
    full    : out std_logic;

    rd_en   : in std_logic;
    rd_data : out std_logic_vector(WIDTH - 1 downto 0);
    empty   : out std_logic
  );
end entity sync_fifo;

architecture rtl of sync_fifo is
  type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  signal wr_ptr : natural range 0 to DEPTH - 1 := 0;
  signal rd_ptr : natural range 0 to DEPTH - 1 := 0;
  signal count  : natural range 0 to DEPTH := 0;
begin

  process (clk)
    variable did_wr, did_rd : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wr_ptr <= 0;
        rd_ptr <= 0;
        count <= 0;
      else
        did_wr := (wr_en = '1' and count < DEPTH);
        did_rd := (rd_en = '1' and count > 0);

        if did_wr then
          mem(wr_ptr) <= wr_data;
          if wr_ptr = DEPTH - 1 then
            wr_ptr <= 0;
          else
            wr_ptr <= wr_ptr + 1;
          end if;
        end if;

        if did_rd then
          rd_data <= mem(rd_ptr);
          if rd_ptr = DEPTH - 1 then
            rd_ptr <= 0;
          else
            rd_ptr <= rd_ptr + 1;
          end if;
        end if;

        if did_wr and not did_rd then
          count <= count + 1;
        elsif did_rd and not did_wr then
          count <= count - 1;
        end if;
      end if;
    end if;
  end process;

  full  <= '1' when count = DEPTH else '0';
  empty <= '1' when count = 0 else '0';

end architecture rtl;
