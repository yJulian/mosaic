library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_types.all;

-- OS-mode staging test: skew_feeder + ws_weight_loader + systolic_array
-- wired together, with stage_wen/stage_idx/stage_data driven directly by
-- this testbench (array_ctrl's nested-counter address generation is
-- deliberately NOT involved yet -- that's sim/tb_core_integration.vhd's
-- job). Isolates "is the feeder's os_regs read/write formula right" from
-- "is array_ctrl's address generation right", per docs/architecture.md's
-- staged verification approach for this feature. Same K sweep as
-- sim/tb_systolic_array.vhd (which already locked down the
-- OS_FEED_CYCLES(k_len) timing formula in isolation from staging).
entity tb_os_feeders is
end entity tb_os_feeders;

architecture sim of tb_os_feeders is
  constant CLK_PERIOD : time := 10 ns;

  type matrix6_t is array (0 to ARRAY_ROWS - 1, 0 to ARRAY_COLS - 1) of integer;

  -- Same test data generators as sim/tb_systolic_array.vhd (duplicated,
  -- not shared -- matches this repo's existing per-testbench convention,
  -- see sim/tb_core_integration.vhd's own duplicated A_MAT/W_MAT/matmul).
  function ext_a_val(m, k : integer) return integer is
  begin
    return ((m * 5 + k * 3 + 7) mod 41) - 20;
  end function;

  function ext_w_val(k, n : integer) return integer is
  begin
    return ((k * 7 + n * 2 + 11) mod 37) - 18;
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

  signal mode         : pe_mode_t := PE_IDLE;
  signal os_clear     : std_logic := '0';
  signal load_counter : natural range 0 to 2 * ARRAY_ROWS := 0;
  signal phase_cycle  : phase_cycle_t := 0;
  signal k_len_sig    : natural range 1 to OS_K_MAX := ARRAY_ROWS;

  signal a_stage_wen      : std_logic := '0';
  signal a_stage_idx      : natural range 0 to ARRAY_ROWS * OS_K_MAX - 1 := 0;
  signal a_stage_data     : std_logic_vector(7 downto 0) := (others => '0');
  signal staging_for_ws   : std_logic := '0';

  signal w_stage_wen  : std_logic := '0';
  signal w_stage_idx  : natural range 0 to OS_K_MAX * ARRAY_COLS - 1 := 0;
  signal w_stage_data : std_logic_vector(7 downto 0) := (others => '0');

  signal act_west   : act_vec_t;
  signal wgt_north  : wgt_vec_t;
  signal psum_north : psum_vec_t := (others => (others => '0'));
  signal act_east   : act_vec_t;
  signal wgt_south  : wgt_vec_t;
  signal psum_south : psum_vec_t;

  signal debug_row    : natural range 0 to ARRAY_ROWS - 1 := 0;
  signal debug_col    : natural range 0 to ARRAY_COLS - 1 := 0;
  signal debug_weight : data_t;
  signal debug_accum  : acc_t;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  afeed : entity work.skew_feeder
    port map (
      clk => clk,
      stage_wen => a_stage_wen, stage_idx => a_stage_idx, stage_data => a_stage_data,
      staging_for_ws => staging_for_ws,
      mode => mode, phase_cycle => phase_cycle, k_len => k_len_sig,
      act_west => act_west
    );

  wload : entity work.ws_weight_loader
    port map (
      clk => clk,
      stage_wen => w_stage_wen, stage_idx => w_stage_idx, stage_data => w_stage_data,
      mode => mode, phase_cycle => phase_cycle, k_len => k_len_sig,
      wgt_north => wgt_north
    );

  arr : entity work.systolic_array
    port map (
      clk => clk, rst => '0',
      mode => mode, os_clear => os_clear, load_counter => load_counter,
      act_west => act_west, wgt_north => wgt_north, psum_north => psum_north,
      act_east => act_east, wgt_south => wgt_south, psum_south => psum_south,
      debug_weight => debug_weight, debug_accum => debug_accum,
      debug_row => debug_row, debug_col => debug_col
    );

  clk_gen : process
  begin
    while not sim_done loop
      clk <= '0'; wait for CLK_PERIOD / 2;
      clk <= '1'; wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process;

  stim : process
    procedure check_acc(actual : acc_t; expected : integer; msg : string) is
    begin
      if to_integer(actual) /= expected then
        report "FAIL: " & msg & " got=" & integer'image(to_integer(actual)) &
               " exp=" & integer'image(expected) severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    variable k_len    : integer;
    variable golden_k : matrix6_t;
  begin
    wait until rising_edge(clk);

    for ki in K_SWEEP'range loop
      k_len := K_SWEEP(ki);
      k_len_sig <= k_len;
      golden_k := matmul_k(k_len);

      ------------------------------------------------------------------
      -- Stage weights: dense K x ARRAY_COLS, row-major -- linear copy,
      -- same layout the real array_ctrl's STAGE_W will use (no nested
      -- counters needed for weights, see rtl/feeder/ws_weight_loader.vhd).
      ------------------------------------------------------------------
      for idx in 0 to k_len * ARRAY_COLS - 1 loop
        w_stage_idx <= idx;
        w_stage_data <= std_logic_vector(to_signed(ext_w_val(idx / ARRAY_COLS, idx mod ARRAY_COLS), 8));
        w_stage_wen <= '1';
        wait until rising_edge(clk);
      end loop;
      w_stage_wen <= '0';

      ------------------------------------------------------------------
      -- Stage activations: dense M x k_len source, but os_regs is
      -- M-major with a fixed OS_K_MAX stride -- the nested (m,k) write
      -- addressing array_ctrl's STAGE_A-for-OS will generate, driven
      -- directly here since array_ctrl isn't in this test.
      ------------------------------------------------------------------
      staging_for_ws <= '0';
      for m in 0 to ARRAY_ROWS - 1 loop
        for k in 0 to k_len - 1 loop
          a_stage_idx <= m * OS_K_MAX + k;
          a_stage_data <= std_logic_vector(to_signed(ext_a_val(m, k), 8));
          a_stage_wen <= '1';
          wait until rising_edge(clk);
        end loop;
      end loop;
      a_stage_wen <= '0';

      ------------------------------------------------------------------
      -- Compute: manually drive phase_cycle the way array_ctrl would
      -- (phase_cycle=0 is the os_clear-only cycle, matching
      -- OS_FEED_CYCLES(k_len) = ARRAY_ROWS+ARRAY_COLS+k_len total cycles,
      -- already validated in isolation by sim/tb_systolic_array.vhd).
      ------------------------------------------------------------------
      mode <= PE_COMPUTE_OS;
      os_clear <= '1';
      phase_cycle <= 0;
      wait until rising_edge(clk);
      os_clear <= '0';

      for pc in 1 to ARRAY_ROWS + ARRAY_COLS + k_len - 1 loop
        phase_cycle <= pc;
        wait until rising_edge(clk);
      end loop;

      mode <= PE_DRAIN_OS;
      psum_north <= (others => (others => '0'));
      wait for 1 ns;
      for c in 0 to ARRAY_COLS - 1 loop
        check_acc(psum_south(c), golden_k(ARRAY_ROWS - 1, c),
          "OS(k=" & integer'image(k_len) & ") drain row " & integer'image(ARRAY_ROWS - 1) & " col " & integer'image(c));
      end loop;

      for r in ARRAY_ROWS - 2 downto 0 loop
        wait until rising_edge(clk);
        wait for 1 ns;
        for c in 0 to ARRAY_COLS - 1 loop
          check_acc(psum_south(c), golden_k(r, c),
            "OS(k=" & integer'image(k_len) & ") drain row " & integer'image(r) & " col " & integer'image(c));
        end loop;
      end loop;

      mode <= PE_IDLE;
      wait until rising_edge(clk);
    end loop;

    ------------------------------------------------------------------
    report "tb_os_feeders: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_os_feeders FAILED" severity failure;
    else
      report "tb_os_feeders PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
