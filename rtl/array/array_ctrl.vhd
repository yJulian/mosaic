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
-- STAGE_W/STAGE_A burst-read from the scratchpad (via stage_addr/
-- stage_data) into ws_weight_loader's / skew_feeder's local register
-- files -- this exists because the systolic array needs cycle-accurate
-- data with no memory-read latency mixed in, which a single BSRAM read
-- port cannot provide once multiple rows/columns need data in the same
-- cycle. For WS (always exactly 36 bytes each, K fixed at ARRAY_ROWS)
-- this is unchanged from the original design. For OS, K is a runtime
-- value (k_len_reg, latched from the host at start_compute_os, up to
-- OS_K_MAX) -- STAGE_W stays a simple linear copy (k_len_reg*ARRAY_COLS
-- bytes: weight's row-major stride is ARRAY_COLS, always fixed, since N
-- never changes), but STAGE_A needs two small nested counters
-- (os_m_ctr/os_k_ctr) because the source scratchpad data is densely
-- packed M-major/K-minor (stride=k_len_reg, a *runtime* value) while
-- skew_feeder's OS-mode storage needs a *fixed* compile-time stride
-- (OS_K_MAX) -- see rtl/feeder/skew_feeder.vhd and
-- sim/tb_core_integration.vhd for the derivation/cross-check.
--
-- WRITEBACK burst-writes result_drainer's local 36x32-bit register file
-- (144 bytes) out to the scratchpad's result region -- this exists for
-- the mirror-image reason: during COMPUTE_WS/DRAIN_OS, up to ARRAY_COLS
-- results can become valid in the same cycle (confirmed by simulation),
-- far more than a single byte-wide scratchpad write port can absorb, so
-- results are captured into local registers first and drained out after.
-- M and N stay fixed at ARRAY_ROWS/ARRAY_COLS regardless of K, so this
-- phase is completely unaffected by the OS-mode K generalization.
--
-- Cycle counts for LOAD/COMPUTE_WS/DRAIN_OS are the same
-- empirically-validated values from the original array_ctrl (see
-- sim/tb_systolic_array.vhd). OS_FEED_CYCLES is now a function of
-- k_len_reg (ARRAY_ROWS+ARRAY_COLS+k_len_reg) instead of a compile-time
-- constant -- also re-derived and confirmed in sim/tb_systolic_array.vhd,
-- independent of this file's own staging logic.
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
    phase_cycle  : out phase_cycle_t;

    -- OS contraction length, decoded+range-validated by cmd_processor
    -- before it ever pulses start_compute_os (see rtl/ctrl/cmd_processor.vhd)
    -- -- latched into k_len_reg below at that moment, so the to_integer
    -- conversion is always in-range when it happens. Ignored entirely
    -- for WS (K is always ARRAY_ROWS there).
    k_len_raw : in unsigned(15 downto 0);

    -- latched, range-constrained version of k_len_raw (see k_len_reg
    -- below) -- what ws_weight_loader/skew_feeder actually consume during
    -- STAGE_A-for-OS/S_COMPUTE_OS.
    k_len : out natural range 1 to OS_K_MAX;

    -- exposes the internal pending_ws latch so skew_feeder knows which
    -- of its two register files a STAGE_A write should target.
    staging_for_ws : out std_logic;

    -- Debug-only: exposes the STAGE_A-for-OS nested address counters so a
    -- testbench can assert phase_counter = os_m_ctr*k_len+os_k_ctr every
    -- cycle (a counter desync would otherwise only show up several steps
    -- later as a wrong result byte) -- see sim/tb_core_integration.vhd.
    -- Not consumed anywhere in top.vhd, safe to leave unconnected there.
    dbg_phase_counter : out natural range 0 to ARRAY_ROWS * OS_K_MAX + RESULT_BYTES;
    dbg_os_m_ctr      : out natural range 0 to ARRAY_ROWS - 1;
    dbg_os_k_ctr      : out natural range 0 to OS_K_MAX - 1;
    dbg_staging_a_os  : out std_logic; -- '1' exactly when the counters above are live

    -- scratchpad read port, used only during STAGE_W/STAGE_A
    stage_addr : out unsigned(ADDR_WIDTH - 1 downto 0);
    stage_data : in std_logic_vector(7 downto 0);

    -- staging register file write-enables (ws_weight_loader / skew_feeder)
    stage_w_wen : out std_logic;
    stage_w_idx : out natural range 0 to OS_K_MAX * ARRAY_COLS - 1;
    stage_a_wen : out std_logic;
    stage_a_idx : out natural range 0 to ARRAY_ROWS * OS_K_MAX - 1;

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
  signal done_latch    : std_logic := '0';

  -- Must cover the largest value phase_counter reaches in ANY state, not
  -- just STAGE_A-for-OS's ARRAY_ROWS*OS_K_MAX -- WRITEBACK's RESULT_BYTES-1
  -- is K-independent (M,N always fixed at 6) and, for small OS_K_MAX, can
  -- exceed ARRAY_ROWS*OS_K_MAX (e.g. OS_K_MAX=16: 96 vs 143) -- a real
  -- range-check failure caught only by actually simulating a smaller
  -- OS_K_MAX, not by inspection. Just sum both rather than a max() call:
  -- always sufficient, and the extra couple of counter bits cost nothing.
  constant PHASE_COUNTER_MAX : natural := ARRAY_ROWS * OS_K_MAX + RESULT_BYTES;
  signal phase_counter : natural range 0 to PHASE_COUNTER_MAX := 0;

  signal k_len_reg : natural range 1 to OS_K_MAX := ARRAY_ROWS;

  -- Nested STAGE_A-for-OS address counters -- see the file header comment.
  -- os_m_ctr/os_k_ctr drive the CURRENT read address; the _prev pair is a
  -- plain 1-cycle register delay (not arithmetic -- a linear "-1" doesn't
  -- work across a counter-pair wraparound) used for the write-side index,
  -- mirroring the same registered-read-latency pattern STAGE_W/WS's
  -- STAGE_A already use via "phase_counter - 1".
  signal os_m_ctr, os_m_ctr_prev : natural range 0 to ARRAY_ROWS - 1 := 0;
  signal os_k_ctr, os_k_ctr_prev : natural range 0 to OS_K_MAX - 1 := 0;

  constant STAGE_CYCLES    : natural := WEIGHT_BYTES + 1; -- WS only; = ACT_BYTES+1 too (both 36)
  constant LOAD_CYCLES     : natural := 2 * ARRAY_ROWS - 1;
  constant WS_CYCLES       : natural := 2 * ARRAY_ROWS + ARRAY_COLS - 1;
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
        k_len_reg <= ARRAY_ROWS;
        os_m_ctr <= 0; os_m_ctr_prev <= 0;
        os_k_ctr <= 0; os_k_ctr_prev <= 0;
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
              k_len_reg <= to_integer(k_len_raw);
            end if;

          when S_STAGE_W =>
            if pending_ws = '1' then
              if phase_counter = STAGE_CYCLES - 1 then
                state <= S_STAGE_A;
                phase_counter <= 0;
                os_m_ctr <= 0; os_m_ctr_prev <= 0;
                os_k_ctr <= 0; os_k_ctr_prev <= 0;
              else
                phase_counter <= phase_counter + 1;
              end if;
            else
              if phase_counter = k_len_reg * ARRAY_COLS then
                state <= S_STAGE_A;
                phase_counter <= 0;
                os_m_ctr <= 0; os_m_ctr_prev <= 0;
                os_k_ctr <= 0; os_k_ctr_prev <= 0;
              else
                phase_counter <= phase_counter + 1;
              end if;
            end if;

          when S_STAGE_A =>
            if pending_ws = '1' then
              if phase_counter = STAGE_CYCLES - 1 then
                phase_counter <= 0;
                state <= S_LOAD;
              else
                phase_counter <= phase_counter + 1;
              end if;
            else
              -- nested (m,k) address-counter advance, one step per cycle,
              -- with an explicit terminal guard: without one, the last
              -- valid pair would try to push os_m_ctr past ARRAY_ROWS-1,
              -- violating its own range (a real range-check failure in
              -- every OS run, caught only by actually simulating this).
              os_m_ctr_prev <= os_m_ctr;
              os_k_ctr_prev <= os_k_ctr;
              if not (os_m_ctr = ARRAY_ROWS - 1 and os_k_ctr = k_len_reg - 1) then
                if os_k_ctr = k_len_reg - 1 then
                  os_k_ctr <= 0;
                  os_m_ctr <= os_m_ctr + 1;
                else
                  os_k_ctr <= os_k_ctr + 1;
                end if;
              end if;

              if phase_counter = ARRAY_ROWS * k_len_reg then
                phase_counter <= 0;
                state <= S_COMPUTE_OS;
              else
                phase_counter <= phase_counter + 1;
              end if;
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
            -- OS_FEED_CYCLES(k_len) = ARRAY_ROWS+ARRAY_COLS+k_len_reg,
            -- re-derived and confirmed (K=6/3/10/1/OS_K_MAX) in
            -- sim/tb_systolic_array.vhd independent of this staging logic.
            if phase_counter = ARRAY_ROWS + ARRAY_COLS + k_len_reg - 1 then
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
  staging_for_ws <= pending_ws;
  k_len <= k_len_reg;
  dbg_phase_counter <= phase_counter;
  dbg_os_m_ctr <= os_m_ctr;
  dbg_os_k_ctr <= os_k_ctr;
  dbg_staging_a_os <= '1' when (state = S_STAGE_A and pending_ws = '0') else '0';

  mode <= PE_LOAD_WEIGHT when state = S_LOAD else
          PE_COMPUTE_WS  when state = S_COMPUTE_WS else
          PE_COMPUTE_OS  when state = S_COMPUTE_OS else
          PE_DRAIN_OS    when state = S_DRAIN_OS else
          PE_IDLE;

  os_clear <= '1' when (state = S_COMPUTE_OS and phase_counter = 0) else '0';
  load_counter <= phase_counter when state = S_LOAD else 0;

  -- phase_cycle only ever needs to reflect phase_counter during the
  -- states that actually consume it (systolic_array/feeders' drive_proc
  -- branch on mode, which is PE_IDLE elsewhere) -- gating by state instead
  -- of numerically clamping the way the original single-K design did
  -- keeps this always within phase_cycle_t's range even though
  -- phase_counter itself legitimately runs much higher during
  -- STAGE_A-for-OS (up to PHASE_COUNTER_MAX=192 at OS_K_MAX=32, versus
  -- phase_cycle_t's max of ARRAY_ROWS+ARRAY_COLS+OS_K_MAX-1=43).
  phase_cycle <= phase_counter when (state = S_LOAD or state = S_COMPUTE_WS or
                                      state = S_COMPUTE_OS or state = S_DRAIN_OS)
                 else 0;

  -- STAGE_W: read WEIGHT_BASE+i, capture into stage_w regfile[i] one
  -- cycle later (registered read latency). Linear regardless of mode --
  -- weight's row-major stride (ARRAY_COLS=N) never changes, only the row
  -- count (K) does, so only the upper bound differs by pending_ws.
  -- STAGE_A: WS keeps the original linear ACT_BASE+phase_counter read
  -- (unchanged); OS reads via the nested os_m_ctr/os_k_ctr pair since the
  -- destination (skew_feeder's os_regs) needs a fixed OS_K_MAX stride
  -- while the source is densely packed at the runtime k_len_reg stride.
  stage_addr <= to_unsigned(WEIGHT_BASE + phase_counter, ADDR_WIDTH)
                  when (state = S_STAGE_W and
                        ((pending_ws = '1' and phase_counter <= WEIGHT_BYTES - 1) or
                         (pending_ws = '0' and phase_counter <= k_len_reg * ARRAY_COLS - 1))) else
                to_unsigned(ACT_BASE + phase_counter, ADDR_WIDTH)
                  when (state = S_STAGE_A and pending_ws = '1' and phase_counter <= ACT_BYTES - 1) else
                to_unsigned(ACT_BASE + os_m_ctr * k_len_reg + os_k_ctr, ADDR_WIDTH)
                  when (state = S_STAGE_A and pending_ws = '0' and phase_counter <= ARRAY_ROWS * k_len_reg - 1) else
                (others => '0');

  -- No pending_ws branch needed here: the underlying regs array in
  -- ws_weight_loader is unified (linear addressing works for any K), and
  -- the state machine above already exits S_STAGE_W exactly one cycle
  -- after the last valid write regardless of which mode is pending.
  stage_w_wen <= '1' when (state = S_STAGE_W and phase_counter >= 1) else '0';
  stage_w_idx <= phase_counter - 1 when (state = S_STAGE_W and phase_counter >= 1) else 0;

  stage_a_wen <= '1' when (state = S_STAGE_A and phase_counter >= 1) else '0';
  stage_a_idx <= (phase_counter - 1) when (state = S_STAGE_A and pending_ws = '1' and phase_counter >= 1) else
                 (os_m_ctr_prev * OS_K_MAX + os_k_ctr_prev) when (state = S_STAGE_A and pending_ws = '0' and phase_counter >= 1) else
                 0;

  -- WRITEBACK: drain result_drainer's local regfile out to RESULT_BASE.
  -- M,N fixed at ARRAY_ROWS/ARRAY_COLS regardless of K, so this is
  -- completely unaffected by the OS K generalization.
  wb_idx <= phase_counter when (state = S_WRITEBACK and phase_counter <= RESULT_BYTES - 1) else 0;
  wb_addr <= to_unsigned(RESULT_BASE + phase_counter, ADDR_WIDTH) when state = S_WRITEBACK else to_unsigned(RESULT_BASE, ADDR_WIDTH);
  wb_wen <= '1' when state = S_WRITEBACK else '0';

end architecture rtl;
