library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_types.all;
use work.pkg_memmap.all;

-- Full "core" integration test (no UART yet): scratchpad + array_ctrl +
-- systolic_array + ws_weight_loader + skew_feeder + result_drainer wired
-- together exactly as top.vhd will wire them. Weight/activation matrices
-- are poked directly into the scratchpad (standing in for what
-- cmd_processor's WRITE_WEIGHTS/WRITE_ACTIVATIONS will do later); a
-- single start_compute_ws / start_compute_os pulse is expected to run the
-- entire STAGE->LOAD/COMPUTE->DRAIN->WRITEBACK sequence autonomously and
-- land the correct int32 result matrix in the scratchpad's result region.
--
-- WS stays a fixed 6x6 regression (unaffected by the OS K generalization).
-- OS is swept across several K values, with dense M-major/K-minor
-- activation bytes and dense K-major/N-minor weight bytes poked at their
-- *realistic runtime shape* (exactly what a real WRITE_ACTIVATIONS/
-- WRITE_WEIGHTS would carry) -- this is what actually exercises
-- array_ctrl's real STAGE_W pending_ws-branch and STAGE_A nested-counter
-- address generation end to end (sim/tb_os_feeders.vhd already validated
-- the same addressing with array_ctrl bypassed; this is the "is
-- array_ctrl's own counter generation right" half of that split).
entity tb_core_integration is
end entity tb_core_integration;

architecture sim of tb_core_integration is
  constant CLK_PERIOD : time := 10 ns;

  type matrix6_t is array (0 to ARRAY_ROWS - 1, 0 to ARRAY_COLS - 1) of integer;

  constant A_MAT : matrix6_t := (
    (1, 2, 3, 4, 5, 6),
    (7, 8, 9, 10, 11, 12),
    (13, 14, 15, 16, 17, 18),
    (-1, -2, -3, -4, -5, -6),
    (2, 4, 6, 8, 10, 12),
    (0, 1, 0, 1, 0, 1)
  );

  constant W_MAT : matrix6_t := (
    (1, 0, 0, 1, 0, 0),
    (0, 1, 0, 0, 1, 0),
    (0, 0, 1, 0, 0, 1),
    (2, 0, 0, 2, 0, 0),
    (0, 2, 0, 0, 2, 0),
    (0, 0, 2, 0, 0, 2)
  );

  function matmul(a, w : matrix6_t) return matrix6_t is
    variable result : matrix6_t;
    variable sum     : integer;
  begin
    for m in 0 to ARRAY_ROWS - 1 loop
      for c in 0 to ARRAY_COLS - 1 loop
        sum := 0;
        for k in 0 to ARRAY_ROWS - 1 loop
          sum := sum + a(m, k) * w(k, c);
        end loop;
        result(m, c) := sum;
      end loop;
    end loop;
    return result;
  end function;

  constant GOLDEN_C : matrix6_t := matmul(A_MAT, W_MAT);

  -- Same OS K-sweep test data generators as sim/tb_systolic_array.vhd /
  -- sim/tb_os_feeders.vhd (duplicated, not shared -- matches this
  -- repo's existing per-testbench convention). k<ARRAY_ROWS reproduces
  -- A_MAT/W_MAT exactly, so K=ARRAY_ROWS is a true regression tie-in.
  function ext_a_val(m, k : integer) return integer is
  begin
    if k < ARRAY_ROWS then
      return A_MAT(m, k);
    else
      return ((m * 5 + k * 3 + 7) mod 41) - 20;
    end if;
  end function;

  function ext_w_val(k, n : integer) return integer is
  begin
    if k < ARRAY_ROWS then
      return W_MAT(k, n);
    else
      return ((k * 7 + n * 2 + 11) mod 37) - 18;
    end if;
  end function;

  function matmul_k(k_len : integer) return matrix6_t is
    variable result : matrix6_t;
    variable sum     : integer;
  begin
    for m in 0 to ARRAY_ROWS - 1 loop
      for c in 0 to ARRAY_COLS - 1 loop
        sum := 0;
        for k in 0 to k_len - 1 loop
          sum := sum + ext_a_val(m, k) * ext_w_val(k, c);
        end loop;
        result(m, c) := sum;
      end loop;
    end loop;
    return result;
  end function;

  type k_sweep_t is array (natural range <>) of integer;
  constant K_SWEEP : k_sweep_t(0 to 4) := (6, 3, 10, 1, OS_K_MAX);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal start_compute_ws, start_compute_os : std_logic := '0';
  signal busy, done : std_logic;
  signal k_len_raw : unsigned(15 downto 0) := to_unsigned(ARRAY_ROWS, 16);
  signal k_len_val : natural range 1 to OS_K_MAX;
  signal staging_for_ws : std_logic;

  -- debug taps for the STAGE_A-for-OS nested-counter invariant check
  -- (see the monitor process below); k_len_expected is set by the stim
  -- process right before each OS run, since it already knows what value
  -- it just told array_ctrl to latch.
  signal dbg_phase_counter : natural range 0 to ARRAY_ROWS * OS_K_MAX + RESULT_BYTES;
  signal dbg_os_m_ctr      : natural range 0 to ARRAY_ROWS - 1;
  signal dbg_os_k_ctr      : natural range 0 to OS_K_MAX - 1;
  signal dbg_staging_a_os  : std_logic;
  signal k_len_expected    : natural range 1 to OS_K_MAX := ARRAY_ROWS;
  signal monitor_errors    : natural := 0;

  signal mode         : pe_mode_t;
  signal os_clear     : std_logic;
  signal load_counter : natural range 0 to 2 * ARRAY_ROWS;
  signal phase_cycle  : phase_cycle_t;

  signal stage_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal stage_data  : std_logic_vector(7 downto 0);
  signal stage_w_wen : std_logic;
  signal stage_w_idx : natural range 0 to OS_K_MAX * ARRAY_COLS - 1;
  signal stage_a_wen : std_logic;
  signal stage_a_idx : natural range 0 to ARRAY_ROWS * OS_K_MAX - 1;

  signal wb_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal wb_idx  : natural range 0 to RESULT_BYTES - 1;
  signal wb_wen  : std_logic;
  signal wb_data : std_logic_vector(7 downto 0);

  -- scratchpad external (host-side, TB-driven) port, muxed with the
  -- internal stage/writeback ports exactly as top.vhd will mux them.
  signal host_w_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal host_w_data : std_logic_vector(7 downto 0) := (others => '0');
  signal host_w_en   : std_logic := '0';
  signal host_r_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal host_r_data : std_logic_vector(7 downto 0);

  signal spad_w_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal spad_w_data : std_logic_vector(7 downto 0);
  signal spad_w_en   : std_logic;
  signal spad_r_addr : unsigned(ADDR_WIDTH - 1 downto 0);
  signal spad_r_data : std_logic_vector(7 downto 0);

  signal act_west   : act_vec_t;
  signal wgt_north  : wgt_vec_t;
  signal psum_north : psum_vec_t := (others => (others => '0'));
  signal act_east   : act_vec_t;
  signal wgt_south  : wgt_vec_t;
  signal psum_south : psum_vec_t;

  signal dbg_row : natural range 0 to ARRAY_ROWS - 1 := 0;
  signal dbg_col : natural range 0 to ARRAY_COLS - 1 := 0;
  signal dbg_weight       : data_t;
  signal dbg_accum        : acc_t;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  ctrl : entity work.array_ctrl
    port map (
      clk => clk, rst => rst,
      start_compute_ws => start_compute_ws, start_compute_os => start_compute_os,
      busy => busy, done => done,
      mode => mode, os_clear => os_clear, load_counter => load_counter, phase_cycle => phase_cycle,
      k_len_raw => k_len_raw, k_len => k_len_val, staging_for_ws => staging_for_ws,
      dbg_phase_counter => dbg_phase_counter, dbg_os_m_ctr => dbg_os_m_ctr,
      dbg_os_k_ctr => dbg_os_k_ctr, dbg_staging_a_os => dbg_staging_a_os,
      stage_addr => stage_addr, stage_data => stage_data,
      stage_w_wen => stage_w_wen, stage_w_idx => stage_w_idx,
      stage_a_wen => stage_a_wen, stage_a_idx => stage_a_idx,
      wb_addr => wb_addr, wb_idx => wb_idx, wb_wen => wb_wen
    );

  arr : entity work.systolic_array
    port map (
      clk => clk, rst => rst,
      mode => mode, os_clear => os_clear, load_counter => load_counter,
      act_west => act_west, wgt_north => wgt_north, psum_north => psum_north,
      act_east => act_east, wgt_south => wgt_south, psum_south => psum_south,
      debug_weight => dbg_weight, debug_accum => dbg_accum,
      debug_row => dbg_row, debug_col => dbg_col
    );

  wload : entity work.ws_weight_loader
    port map (
      clk => clk,
      stage_wen => stage_w_wen, stage_idx => stage_w_idx, stage_data => stage_data,
      mode => mode, phase_cycle => phase_cycle, k_len => k_len_val,
      wgt_north => wgt_north
    );

  afeed : entity work.skew_feeder
    port map (
      clk => clk,
      stage_wen => stage_a_wen, stage_idx => stage_a_idx, stage_data => stage_data,
      staging_for_ws => staging_for_ws,
      mode => mode, phase_cycle => phase_cycle, k_len => k_len_val,
      act_west => act_west
    );

  drainer : entity work.result_drainer
    port map (
      clk => clk,
      mode => mode, phase_cycle => phase_cycle, psum_south => psum_south,
      wb_idx => wb_idx, wb_data => wb_data
    );

  -- Port mux: internal (staging/writeback) owns the scratchpad while
  -- busy; host (TB) owns it while idle -- same policy top.vhd will use.
  spad_r_addr <= stage_addr when busy = '1' else host_r_addr;
  spad_w_addr <= wb_addr when busy = '1' else host_w_addr;
  spad_w_data <= wb_data when busy = '1' else host_w_data;
  spad_w_en   <= wb_wen when busy = '1' else host_w_en;
  stage_data  <= spad_r_data;
  host_r_data <= spad_r_data;

  spad : entity work.scratchpad
    port map (
      clk => clk,
      w_addr => spad_w_addr, w_data => spad_w_data, w_en => spad_w_en,
      r_addr => spad_r_addr, r_data => spad_r_data
    );

  clk_gen : process
  begin
    while not sim_done loop
      clk <= '0'; wait for CLK_PERIOD / 2;
      clk <= '1'; wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process;

  -- STAGE_A-for-OS nested-counter invariant: phase_counter should always
  -- equal os_m_ctr*k_len+os_k_ctr while the counters are live, except on
  -- the one "extra" settle cycle after the terminal guard has stopped
  -- them (excluded via the <= bound below) -- a desync here fails at the
  -- cycle it happens instead of only showing up as a wrong result byte
  -- several stages later. Separate error counter from `errors` since
  -- VHDL doesn't allow two processes driving the same unresolved signal.
  monitor : process (clk)
  begin
    if rising_edge(clk) then
      if dbg_staging_a_os = '1' and dbg_phase_counter <= ARRAY_ROWS * k_len_expected - 1 then
        if dbg_phase_counter /= dbg_os_m_ctr * k_len_expected + dbg_os_k_ctr then
          report "FAIL: STAGE_A-for-OS counter desync: phase_counter=" & integer'image(dbg_phase_counter) &
                 " os_m_ctr=" & integer'image(dbg_os_m_ctr) & " os_k_ctr=" & integer'image(dbg_os_k_ctr) &
                 " k_len=" & integer'image(k_len_expected) severity error;
          monitor_errors <= monitor_errors + 1;
        end if;
      end if;
    end if;
  end process;

  stim : process
    procedure check_int(actual : integer; expected : integer; msg : string) is
    begin
      if actual /= expected then
        report "FAIL: " & msg & " got=" & integer'image(actual) &
               " exp=" & integer'image(expected) severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    procedure poke_matrix(base : natural; m : matrix6_t) is
    begin
      for r in 0 to ARRAY_ROWS - 1 loop
        for c in 0 to ARRAY_COLS - 1 loop
          host_w_addr <= to_unsigned(base + r * ARRAY_COLS + c, ADDR_WIDTH);
          host_w_data <= std_logic_vector(to_signed(m(r, c), 8));
          host_w_en <= '1';
          wait until rising_edge(clk);
        end loop;
      end loop;
      host_w_en <= '0';
    end procedure;

    -- Dense M x k_len activation bytes (M-major/K-minor, exactly what a
    -- real WRITE_ACTIVATIONS carries) and dense k_len x N weight bytes
    -- (K-major/N-minor) -- the realistic runtime shapes array_ctrl's
    -- STAGE_W/STAGE_A-for-OS actually consume, as opposed to poke_matrix's
    -- fixed 6x6 shape above.
    procedure poke_activations_k(k_len : natural) is
    begin
      for m in 0 to ARRAY_ROWS - 1 loop
        for k in 0 to k_len - 1 loop
          host_w_addr <= to_unsigned(ACT_BASE + m * k_len + k, ADDR_WIDTH);
          host_w_data <= std_logic_vector(to_signed(ext_a_val(m, k), 8));
          host_w_en <= '1';
          wait until rising_edge(clk);
        end loop;
      end loop;
      host_w_en <= '0';
    end procedure;

    procedure poke_weights_k(k_len : natural) is
    begin
      for k in 0 to k_len - 1 loop
        for n in 0 to ARRAY_COLS - 1 loop
          host_w_addr <= to_unsigned(WEIGHT_BASE + k * ARRAY_COLS + n, ADDR_WIDTH);
          host_w_data <= std_logic_vector(to_signed(ext_w_val(k, n), 8));
          host_w_en <= '1';
          wait until rising_edge(clk);
        end loop;
      end loop;
      host_w_en <= '0';
    end procedure;

    procedure read_results(prefix : string; golden : matrix6_t) is
      variable byte0, byte1, byte2, byte3 : integer;
      variable raw : integer;
    begin
      for r in 0 to ARRAY_ROWS - 1 loop
        for c in 0 to ARRAY_COLS - 1 loop
          host_r_addr <= to_unsigned(RESULT_BASE + (r * ARRAY_COLS + c) * 4, ADDR_WIDTH);
          wait until rising_edge(clk);
          wait for 1 ns;
          byte0 := to_integer(unsigned(host_r_data));
          host_r_addr <= to_unsigned(RESULT_BASE + (r * ARRAY_COLS + c) * 4 + 1, ADDR_WIDTH);
          wait until rising_edge(clk);
          wait for 1 ns;
          byte1 := to_integer(unsigned(host_r_data));
          host_r_addr <= to_unsigned(RESULT_BASE + (r * ARRAY_COLS + c) * 4 + 2, ADDR_WIDTH);
          wait until rising_edge(clk);
          wait for 1 ns;
          byte2 := to_integer(unsigned(host_r_data));
          host_r_addr <= to_unsigned(RESULT_BASE + (r * ARRAY_COLS + c) * 4 + 3, ADDR_WIDTH);
          wait until rising_edge(clk);
          wait for 1 ns;
          byte3 := to_integer(unsigned(host_r_data));
          raw := to_integer(signed(std_logic_vector(to_unsigned(byte3, 8)) &
                                    std_logic_vector(to_unsigned(byte2, 8)) &
                                    std_logic_vector(to_unsigned(byte1, 8)) &
                                    std_logic_vector(to_unsigned(byte0, 8))));
          check_int(raw, golden(r, c),
            prefix & " C(" & integer'image(r) & "," & integer'image(c) & ")");
        end loop;
      end loop;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    ------------------------------------------------------------------
    -- WS run: fixed 6x6, unaffected by the OS K generalization.
    ------------------------------------------------------------------
    poke_matrix(WEIGHT_BASE, W_MAT);
    poke_matrix(ACT_BASE, A_MAT);
    wait until rising_edge(clk);

    start_compute_ws <= '1';
    wait until rising_edge(clk);
    start_compute_ws <= '0';

    wait until done = '1';
    wait for 1 ns;
    read_results("WS", GOLDEN_C);

    wait until rising_edge(clk);

    ------------------------------------------------------------------
    -- OS runs, swept across K -- same sweep set as
    -- sim/tb_systolic_array.vhd / sim/tb_os_feeders.vhd. K=ARRAY_ROWS is
    -- a true regression check (ext_a_val/ext_w_val reproduce A_MAT/W_MAT
    -- exactly for k<ARRAY_ROWS).
    ------------------------------------------------------------------
    for ki in K_SWEEP'range loop
      poke_weights_k(K_SWEEP(ki));
      poke_activations_k(K_SWEEP(ki));
      wait until rising_edge(clk);

      k_len_raw <= to_unsigned(K_SWEEP(ki), 16);
      k_len_expected <= K_SWEEP(ki);
      wait until rising_edge(clk);

      start_compute_os <= '1';
      wait until rising_edge(clk);
      start_compute_os <= '0';

      wait until done = '1';
      wait for 1 ns;
      read_results("OS(k=" & integer'image(K_SWEEP(ki)) & ")", matmul_k(K_SWEEP(ki)));

      wait until rising_edge(clk);
    end loop;

    ------------------------------------------------------------------
    wait for 1 ns; -- let the monitor process's last increment (if any) settle
    report "tb_core_integration: " & integer'image(errors + monitor_errors) & " error(s)";
    if errors + monitor_errors > 0 then
      report "tb_core_integration FAILED" severity failure;
    else
      report "tb_core_integration PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
