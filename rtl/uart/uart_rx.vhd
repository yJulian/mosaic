library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- 8N1 UART receiver, single-clock-domain, center-of-bit sampling (no 16x
-- oversampling -- at 27MHz/1.5Mbaud there are only ~18 clocks per bit,
-- too few for classic 16x-oversample+majority-vote; a short, low-noise,
-- wired point-to-point link doesn't need it, same reasoning as the CRC-8
-- choice in docs/protocol.md). rx is double-flopped for metastability.
entity uart_rx is
  generic (
    CLK_FREQ_HZ : natural := 27_000_000;
    BAUD_RATE   : natural := 1_500_000
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    rx : in std_logic;

    data_out   : out std_logic_vector(7 downto 0);
    data_valid : out std_logic
  );
end entity uart_rx;

architecture rtl of uart_rx is
  constant CLKS_PER_BIT : natural := CLK_FREQ_HZ / BAUD_RATE;

  type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
  signal state : state_t := S_IDLE;

  signal rx_sync0, rx_sync1 : std_logic := '1';
  signal clk_count : natural range 0 to CLKS_PER_BIT - 1 := 0;
  signal bit_idx   : natural range 0 to 7 := 0;
  signal shift_reg : std_logic_vector(7 downto 0) := (others => '0');
begin

  sync_proc : process (clk)
  begin
    if rising_edge(clk) then
      rx_sync0 <= rx;
      rx_sync1 <= rx_sync0;
    end if;
  end process;

  fsm_proc : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE;
        clk_count <= 0;
        bit_idx <= 0;
        data_valid <= '0';
      else
        data_valid <= '0';
        case state is
          when S_IDLE =>
            clk_count <= 0;
            bit_idx <= 0;
            if rx_sync1 = '0' then
              state <= S_START;
            end if;

          when S_START =>
            -- sample at the center of the start bit to reject glitches
            if clk_count = (CLKS_PER_BIT / 2) then
              if rx_sync1 = '0' then
                clk_count <= 0;
                state <= S_DATA;
              else
                state <= S_IDLE;
              end if;
            else
              clk_count <= clk_count + 1;
            end if;

          when S_DATA =>
            if clk_count = CLKS_PER_BIT - 1 then
              clk_count <= 0;
              shift_reg(bit_idx) <= rx_sync1;
              if bit_idx = 7 then
                state <= S_STOP;
              else
                bit_idx <= bit_idx + 1;
              end if;
            else
              clk_count <= clk_count + 1;
            end if;

          when S_STOP =>
            if clk_count = CLKS_PER_BIT - 1 then
              data_out <= shift_reg;
              data_valid <= '1';
              state <= S_IDLE;
            else
              clk_count <= clk_count + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
