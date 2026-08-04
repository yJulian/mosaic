library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;

-- Single Processing Element of the 6x6 systolic array.
--
-- Modes:
--   PE_LOAD_WEIGHT : weights are broadcast down every column from the north
--     edge (row 0 of the weight matrix first, then row 1, ...). Because the
--     array only has neighbor-to-neighbor links, a value fed at global load
--     cycle t reaches physical row r after r register hops, i.e. at global
--     cycle t+r. This PE's row holds W[ROW][*], which was fed at t=ROW, so
--     it arrives here at cycle 2*ROW -- that is the capture condition below.
--     wgt_in is always forwarded south every cycle regardless of capture so
--     lower rows keep receiving the stream.
--   PE_COMPUTE_WS  : weight-stationary compute. Activations flow west->east
--     (registered pass-through), partial sums flow north->south, each PE
--     adding act*weight_stat to the incoming partial sum, one cycle latency.
--   PE_COMPUTE_OS  : output-stationary compute. Both activation and weight
--     stream through every cycle (registered pass-through both directions);
--     the local accumulator adds act_in*wgt_in every cycle. os_clear zeroes
--     the accumulator on the first cycle of a new OS compute.
--   PE_DRAIN_OS    : columnar shift-out. Each PE outputs its current
--     accumulator south (to the row below / south edge) while loading in
--     whatever arrives from the north (its neighbor's old value), turning
--     each column into a 6-deep shift register that empties bottom-first.
entity pe is
  generic (
    ROW : natural;
    COL : natural
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    mode         : in pe_mode_t;
    os_clear     : in std_logic;
    load_counter : in natural range 0 to 2 * ARRAY_ROWS;

    act_in  : in data_t;
    wgt_in  : in data_t;
    psum_in : in acc_t;

    act_out  : out data_t;
    wgt_out  : out data_t;
    psum_out : out acc_t;

    debug_weight : out data_t;
    debug_accum  : out acc_t
  );
end entity pe;

architecture rtl of pe is
  signal act_reg     : data_t := (others => '0');
  signal wgt_reg      : data_t := (others => '0');
  signal weight_stat : data_t := (others => '0');
  signal accum_stat  : acc_t  := (others => '0');
  signal psum_reg    : acc_t  := (others => '0');
  -- (Tried merging psum_reg/accum_stat into one register to save area --
  -- reverted: it made LUT usage *worse*, not better. Consolidating three
  -- mode-branches' worth of next-state logic onto one register produced
  -- a wider select mux than the two simpler separate registers cost in
  -- the first place, confirmed by re-synthesizing both ways. FPGA DFFs
  -- are cheap and pair with a LUT4 slice regardless; the mux feeding
  -- them is what's expensive, so this kind of merge only helps when it
  -- actually simplifies the feeding logic, not just the register count.)

  -- Single shared multiplier for both compute modes (WS uses the
  -- resident weight_stat, OS uses the streamed wgt_in). Writing this as
  -- one combinational signal, instead of a separate "act_in * X"
  -- expression inline in each mode's branch, is what lets synth_gowin
  -- infer exactly one MULT9X9 DSP cell per PE instead of two -- with
  -- two expressions the array needed 72 MULT9X9 against a device
  -- budget of 40, confirmed by nextpnr-himbaechel failing to place them.
  signal mult_b      : data_t;
  signal mult_result : signed(2 * DATA_WIDTH - 1 downto 0);
begin

  mult_b <= weight_stat when mode = PE_COMPUTE_WS else wgt_in;
  mult_result <= act_in * mult_b;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        act_reg     <= (others => '0');
        wgt_reg     <= (others => '0');
        weight_stat <= (others => '0');
        accum_stat  <= (others => '0');
        psum_reg    <= (others => '0');
      else
        case mode is
          when PE_LOAD_WEIGHT =>
            wgt_reg <= wgt_in;
            if load_counter = 2 * ROW then
              weight_stat <= wgt_in;
            end if;

          when PE_COMPUTE_WS =>
            act_reg  <= act_in;
            psum_reg <= psum_in + resize(mult_result, ACC_WIDTH);

          when PE_COMPUTE_OS =>
            act_reg <= act_in;
            wgt_reg <= wgt_in;
            if os_clear = '1' then
              accum_stat <= (others => '0');
            else
              accum_stat <= accum_stat + resize(mult_result, ACC_WIDTH);
            end if;

          when PE_DRAIN_OS =>
            accum_stat <= psum_in;

          when others =>
            null; -- PE_IDLE: hold all registers
        end case;
      end if;
    end if;
  end process;

  act_out  <= act_reg;
  wgt_out  <= wgt_reg;
  psum_out <= psum_reg when mode = PE_COMPUTE_WS else accum_stat;

  debug_weight <= weight_stat;
  debug_accum  <= accum_stat;

end architecture rtl;
