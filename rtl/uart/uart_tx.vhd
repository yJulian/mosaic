library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- 8N1 UART transmitter, single-clock-domain.
entity uart_tx is
  generic (
    CLK_FREQ_HZ : natural := 27_000_000;
    BAUD_RATE   : natural := 1_500_000
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    data_in  : in std_logic_vector(7 downto 0);
    tx_start : in std_logic;
    busy     : out std_logic;

    tx : out std_logic
  );
end entity uart_tx;

architecture rtl of uart_tx is
  constant CLKS_PER_BIT : natural := CLK_FREQ_HZ / BAUD_RATE;

  type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
  signal state : state_t := S_IDLE;

  signal clk_count : natural range 0 to CLKS_PER_BIT - 1 := 0;
  signal bit_idx    : natural range 0 to 7 := 0;
  signal shift_reg  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_reg     : std_logic := '1';
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE;
        clk_count <= 0;
        bit_idx <= 0;
        tx_reg <= '1';
      else
        case state is
          when S_IDLE =>
            tx_reg <= '1';
            clk_count <= 0;
            bit_idx <= 0;
            if tx_start = '1' then
              shift_reg <= data_in;
              state <= S_START;
            end if;

          when S_START =>
            tx_reg <= '0';
            if clk_count = CLKS_PER_BIT - 1 then
              clk_count <= 0;
              state <= S_DATA;
            else
              clk_count <= clk_count + 1;
            end if;

          when S_DATA =>
            tx_reg <= shift_reg(bit_idx);
            if clk_count = CLKS_PER_BIT - 1 then
              clk_count <= 0;
              if bit_idx = 7 then
                state <= S_STOP;
              else
                bit_idx <= bit_idx + 1;
              end if;
            else
              clk_count <= clk_count + 1;
            end if;

          when S_STOP =>
            tx_reg <= '1';
            if clk_count = CLKS_PER_BIT - 1 then
              clk_count <= 0;
              state <= S_IDLE;
            else
              clk_count <= clk_count + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

  tx <= tx_reg;
  busy <= '0' when state = S_IDLE else '1';

end architecture rtl;
