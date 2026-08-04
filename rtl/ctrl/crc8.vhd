library ieee;
use ieee.std_logic_1164.all;

-- CRC-8, poly 0x07, init 0x00, MSB-first, no reflection. Matches
-- python/fpga_systolic/protocol.py's CRC exactly (see docs/protocol.md).
-- One byte processed per byte_valid pulse (8-bit update unrolled into a
-- single combinational function, well within the clock budget at a
-- 27MHz system clock vs a <=3Mbaud UART).
entity crc8 is
  port (
    clk : in std_logic;
    rst : in std_logic;

    init       : in std_logic;
    byte_in    : in std_logic_vector(7 downto 0);
    byte_valid : in std_logic;

    crc_out : out std_logic_vector(7 downto 0)
  );
end entity crc8;

architecture rtl of crc8 is
  signal crc_reg : std_logic_vector(7 downto 0) := (others => '0');

  function crc8_update(crc_in : std_logic_vector(7 downto 0);
                        data_in : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable crc : std_logic_vector(7 downto 0) := crc_in;
  begin
    for i in 7 downto 0 loop
      if (crc(7) xor data_in(i)) = '1' then
        crc := (crc(6 downto 0) & '0') xor x"07";
      else
        crc := crc(6 downto 0) & '0';
      end if;
    end loop;
    return crc;
  end function;
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or init = '1' then
        crc_reg <= (others => '0');
      elsif byte_valid = '1' then
        crc_reg <= crc8_update(crc_reg, byte_in);
      end if;
    end if;
  end process;

  crc_out <= crc_reg;

end architecture rtl;
