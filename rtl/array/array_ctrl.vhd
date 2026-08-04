library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_types.all;
use work.pkg_memmap.all;

-- Top-level compute sequencer. A single start_compute_ws/os pulse now
-- drives the FULL sequence autonomously:
--   IDLE -> STAGE_W -> STAGE_A -> LOAD  -> COMPUTE_WS -> WRITEBACK -> IDLE
--   IDLE -> STAGE_W -> STAGE_A -> COMPUTE_OS -> DRAIN_OS -> WRITEBACK -> IDLE
--
-- STAGE_W/STAGE_A burst-read 36 bytes each from the scratchpad (via
-- stage_addr/stage_data) into ws_weight_loader's / skew_feeder's local
-- 36-byte register files -- this exists because the systolic array needs
-- cycle-accurate data with no memory-read latency mixed in, which a
-- single BSRAM read port cannot provide once multiple rows/columns need
-- data in the same cycle.
--
-- WRITEBACK burst-writes result_drainer's local 36x32-bit register file
-- (144 bytes) out to the scratchpad's result region -- this exists for
-- the mirror-image reason: during COMPUTE_WS/DRAIN_OS, up to ARRAY_COLS
-- results can become valid in the same cycle (confirmed by simulation),
-- far more than a single byte-wide scratchpad write port can absorb, so
-- results are captured into local registers first and drained out after.
--
-- Cycle counts for LOAD/COMPUTE_WS/COMPUTE_OS/DRAIN_OS are the same
-- empirically-validated values from the original array_ctrl (see
-- sim/tb_systolic_array.vhd and sim/tb_array_ctrl.vhd).
entity array_ctrl is
  port (
    clk : in std_logic;
    rst : in std_logic;

    start_compute_ws : in std_logic;
    start_compute_os : in std_logic;

    busy : out std_logic;
    done : out std_logic;

    -- systolic_array control
    mode         : out pe_mode_t;
    os_clear     : out std_logic;
    load_counter : out natural range 0 to 2 * ARRAY_ROWS;
    phase_cycle  : out natural range 0 to 31;

    -- scratchpad read port, used only during STAGE_W/STAGE_A
    stage_addr : out unsigned(ADDR_WIDTH - 1 downto 0);
    stage_data : in std_logic_vector(7 downto 0);

    -- staging register file write-enables (ws_weight_loader / skew_feeder)
    stage_w_wen : out std_logic;
    stage_w_idx : out natural range 0 to WEIGHT_BYTES - 1;
    stage_a_wen : out std_logic;
    stage_a_idx : out natural range 0 to ACT_BYTES - 1;

    -- scratchpad write port control, used only during WRITEBACK. The
    -- actual data byte is wired directly from result_drainer's
    -- byte-extract mux (indexed by wb_idx) to the scratchpad at the
    -- top level -- array_ctrl only sequences address/index/enable.
    wb_addr : out unsigned(ADDR_WIDTH - 1 downto 0);
    wb_idx  : out natural range 0 to RESULT_BYTES - 1;
    wb_wen  : out std_logic
  );
end entity array_ctrl;

architecture rtl of array_ctrl is
  type state_t is (S_RESET, S_IDLE, S_STAGE_W, S_STAGE_A, S_LOAD,
                    S_COMPUTE_WS, S_COMPUTE_OS, S_DRAIN_OS, S_WRITEBACK);
  signal state         : state_t := S_RESET;
  signal pending_ws    : std_logic := '0'; -- which mode we're staging for
  signal phase_counter : natural range 0 to 255 := 0;
  signal done_latch    : std_logic := '0';

  constant STAGE_CYCLES    : natural := WEIGHT_BYTES + 1; -- = ACT_BYTES+1 too (both 36)
  constant LOAD_CYCLES     : natural := 2 * ARRAY_ROWS - 1;
  constant WS_CYCLES       : natural := 2 * ARRAY_ROWS + ARRAY_COLS - 1;
  constant OS_FEED_CYCLES  : natural := 2 * ARRAY_ROWS + ARRAY_COLS;
  constant DRAIN_CYCLES    : natural := ARRAY_ROWS;
  constant WRITEBACK_CYCLES : natural := RESULT_BYTES;
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_RESET;
        phase_counter <= 0;
        done_latch <= '0';
        pending_ws <= '0';
      else
        case state is
          when S_RESET =>
            state <= S_IDLE;

          when S_IDLE =>
            phase_counter <= 0;
            if start_compute_ws = '1' then
              state <= S_STAGE_W;
              pending_ws <= '1';
              done_latch <= '0';
            elsif start_compute_os = '1' then
              state <= S_STAGE_W;
              pending_ws <= '0';
              done_latch <= '0';
            end if;

          when S_STAGE_W =>
            if phase_counter = STAGE_CYCLES - 1 then
              state <= S_STAGE_A;
              phase_counter <= 0;
            else
              phase_counter <= phase_counter + 1;
            end if;

          when S_STAGE_A =>
            if phase_counter = STAGE_CYCLES - 1 then
              phase_counter <= 0;
              if pending_ws = '1' then
                state <= S_LOAD;
              else
                state <= S_COMPUTE_OS;
              end if;
            else
              phase_counter <= phase_counter + 1;
            end if;

          when S_LOAD =>
            if phase_counter = LOAD_CYCLES - 1 then
              state <= S_COMPUTE_WS;
              phase_counter <= 0;
            else
              phase_counter <= phase_counter + 1;
            end if;

          when S_COMPUTE_WS =>
            if phase_counter = WS_CYCLES - 1 then
              state <= S_WRITEBACK;
              phase_counter <= 0;
            else
              phase_counter <= phase_counter + 1;
            end if;

          when S_COMPUTE_OS =>
            if phase_counter = OS_FEED_CYCLES - 1 then
              state <= S_DRAIN_OS;
              phase_counter <= 0;
            else
              phase_counter <= phase_counter + 1;
            end if;

          when S_DRAIN_OS =>
            if phase_counter = DRAIN_CYCLES - 1 then
              state <= S_WRITEBACK;
              phase_counter <= 0;
            else
              phase_counter <= phase_counter + 1;
            end if;

          when S_WRITEBACK =>
            if phase_counter = WRITEBACK_CYCLES - 1 then
              state <= S_IDLE;
              phase_counter <= 0;
              done_latch <= '1';
            else
              phase_counter <= phase_counter + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

  busy <= '0' when (state = S_IDLE or state = S_RESET) else '1';
  done <= done_latch;

  mode <= PE_LOAD_WEIGHT when state = S_LOAD else
          PE_COMPUTE_WS  when state = S_COMPUTE_WS else
          PE_COMPUTE_OS  when state = S_COMPUTE_OS else
          PE_DRAIN_OS    when state = S_DRAIN_OS else
          PE_IDLE;

  os_clear <= '1' when (state = S_COMPUTE_OS and phase_counter = 0) else '0';
  load_counter <= phase_counter when state = S_LOAD else 0;
  phase_cycle <= phase_counter when phase_counter <= 31 else 31;

  -- STAGE_W: read WEIGHT_BASE+i, capture into stage_w regfile[i] one
  -- cycle later (registered read latency).
  stage_addr <= to_unsigned(WEIGHT_BASE + phase_counter, ADDR_WIDTH)
                  when (state = S_STAGE_W and phase_counter <= WEIGHT_BYTES - 1) else
                to_unsigned(ACT_BASE + phase_counter, ADDR_WIDTH)
                  when (state = S_STAGE_A and phase_counter <= ACT_BYTES - 1) else
                (others => '0');

  stage_w_wen <= '1' when (state = S_STAGE_W and phase_counter >= 1) else '0';
  stage_w_idx <= phase_counter - 1 when (state = S_STAGE_W and phase_counter >= 1 and phase_counter <= WEIGHT_BYTES) else 0;

  stage_a_wen <= '1' when (state = S_STAGE_A and phase_counter >= 1) else '0';
  stage_a_idx <= phase_counter - 1 when (state = S_STAGE_A and phase_counter >= 1 and phase_counter <= ACT_BYTES) else 0;

  -- WRITEBACK: drain result_drainer's local regfile out to RESULT_BASE.
  wb_idx <= phase_counter when (state = S_WRITEBACK and phase_counter <= RESULT_BYTES - 1) else 0;
  wb_addr <= to_unsigned(RESULT_BASE + phase_counter, ADDR_WIDTH) when state = S_WRITEBACK else to_unsigned(RESULT_BASE, ADDR_WIDTH);
  wb_wen <= '1' when state = S_WRITEBACK else '0';

end architecture rtl;
