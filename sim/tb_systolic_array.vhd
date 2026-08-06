library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_types.all;

-- Array-level interconnect/timing test. Drives mode/skew stimulus directly
-- (no array_ctrl / feeder yet -- those are tested separately) to validate:
--   1) LOAD_WEIGHT broadcast reaches every one of the 36 PEs correctly.
--   2) COMPUTE_WS: activation fed with a per-row skew of ROW cycles produces
--      C = A @ W at psum_south(c), each output emerging at cycle m+ROWS+c.
--   3) COMPUTE_OS, swept across several K (contraction dimension) values,
--      including K=6 (exact regression against the original hardcoded
--      test), K<6, K>6, K=1 and K=OS_K_MAX -- validates the generalized
--      OS_FEED_CYCLES(k_len) timing formula and skew bounds in complete
--      isolation from array_ctrl/feeder staging risk (see
--      docs/architecture.md and rtl/array/array_ctrl.vhd for why OS mode
--      can stream an arbitrary K while WS mode cannot).
entity tb_systolic_array is
end entity tb_systolic_array;

architecture sim of tb_systolic_array is
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

  -- Extended test data for the OS K-sweep: for k<ARRAY_ROWS these are
  -- bit-identical to A_MAT/W_MAT above (so a k_len=ARRAY_ROWS sweep point
  -- is a true regression against the original hardcoded test), extended
  -- with deterministic small values (well within int8 range) for
  -- k>=ARRAY_ROWS, up to OS_K_MAX. Plain integer-returning functions
  -- instead of materialized 2D constants -- simpler than sizing an
  -- unconstrained array type just for this.
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

  -- Golden C = A @ W for a given contraction length k_len (<= OS_K_MAX).
  -- matmul_k(ARRAY_ROWS) must equal GOLDEN_C above exactly.
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

  signal clk          : std_logic := '0';
  signal rst          : std_logic := '1';
  signal mode         : pe_mode_t := PE_IDLE;
  signal os_clear     : std_logic := '0';
  signal load_counter : natural range 0 to 2 * ARRAY_ROWS := 0;

  signal act_west   : act_vec_t := (others => (others => '0'));
  signal wgt_north  : wgt_vec_t := (others => (others => '0'));
  signal psum_north : psum_vec_t := (others => (others => '0'));
  signal act_east   : act_vec_t;
  signal wgt_south  : wgt_vec_t;
  signal psum_south : psum_vec_t;

  signal debug_row    : natural range 0 to ARRAY_ROWS - 1 := 0;
  signal debug_col     : natural range 0 to ARRAY_COLS - 1 := 0;
  signal debug_weight : data_t;
  signal debug_accum  : acc_t;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  dut : entity work.systolic_array
    port map (
      clk => clk, rst => rst,
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

    procedure check_data(actual : data_t; expected : integer; msg : string) is
    begin
      if to_integer(actual) /= expected then
        report "FAIL: " & msg & " got=" & integer'image(to_integer(actual)) &
               " exp=" & integer'image(expected) severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    variable m : integer;
    variable k_len    : integer;
    variable golden_k : matrix6_t;
  begin
    rst <= '1'; mode <= PE_IDLE;
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    ------------------------------------------------------------------
    -- Test 1: LOAD_WEIGHT broadcast reaches every PE correctly.
    ------------------------------------------------------------------
    mode <= PE_LOAD_WEIGHT;
    for t in 0 to 2 * ARRAY_ROWS loop
      load_counter <= t;
      if t <= ARRAY_ROWS - 1 then
        for c in 0 to ARRAY_COLS - 1 loop
          wgt_north(c) <= to_signed(W_MAT(t, c), DATA_WIDTH);
        end loop;
      end if;
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;

    mode <= PE_IDLE;
    for r in 0 to ARRAY_ROWS - 1 loop
      for c in 0 to ARRAY_COLS - 1 loop
        debug_row <= r; debug_col <= c;
        wait for 1 ns;
        check_data(debug_weight, W_MAT(r, c),
          "LOAD_WEIGHT capture at (" & integer'image(r) & "," & integer'image(c) & ")");
      end loop;
    end loop;

    ------------------------------------------------------------------
    -- Test 2: COMPUTE_WS. Row k gets a k-cycle-skewed feed of column k
    -- of A (i.e. A(g-k, k) at global cycle g). Output C(m,c) emerges at
    -- psum_south(c) at cycle m + ARRAY_ROWS + c.
    ------------------------------------------------------------------
    mode <= PE_COMPUTE_WS;
    for g in 0 to (ARRAY_ROWS - 1) + ARRAY_ROWS + (ARRAY_COLS - 1) loop
      for k in 0 to ARRAY_ROWS - 1 loop
        if g - k >= 0 and g - k <= ARRAY_ROWS - 1 then
          act_west(k) <= to_signed(A_MAT(g - k, k), DATA_WIDTH);
        else
          act_west(k) <= (others => '0');
        end if;
      end loop;
      wait until rising_edge(clk);
      wait for 1 ns;
      for c in 0 to ARRAY_COLS - 1 loop
        -- Empirically confirmed cycle: last-row psum_reg (registered) is
        -- one cycle earlier than a naive "fill + 1" count suggests, because
        -- the register hop that makes row k's contribution visible to row
        -- k+1 already overlaps with row k+1's own combinational compute
        -- cycle instead of adding a fully separate cycle.
        m := g - ARRAY_ROWS - c + 1;
        if m >= 0 and m <= ARRAY_ROWS - 1 then
          check_acc(psum_south(c), GOLDEN_C(m, c),
            "WS output C(" & integer'image(m) & "," & integer'image(c) & ")");
        end if;
      end loop;
    end loop;

    ------------------------------------------------------------------
    -- Test 3: COMPUTE_OS, swept across several K values. Row i (output
    -- row) skewed by i cycles for A, column j (output col) skewed by j
    -- cycles for W -- same skew pattern as before, just bounded by k_len
    -- instead of the hardcoded ARRAY_ROWS. One dedicated clear cycle first
    -- (its data is discarded by the PE's os_clear path).
    ------------------------------------------------------------------
    for ki in K_SWEEP'range loop
      k_len := K_SWEEP(ki);
      golden_k := matmul_k(k_len);

      mode <= PE_COMPUTE_OS;
      os_clear <= '1';
      wait until rising_edge(clk);
      os_clear <= '0';

      -- g_max = (k_len-1) + (ARRAY_ROWS-1): relies on ARRAY_ROWS=ARRAY_COLS
      -- (a standing invariant everywhere else in this codebase too), since
      -- act's and wgt's individual feed spans would otherwise need their
      -- own maxes taken separately.
      for g in 0 to (k_len - 1) + (ARRAY_ROWS - 1) loop
        for i in 0 to ARRAY_ROWS - 1 loop
          if g - i >= 0 and g - i <= k_len - 1 then
            act_west(i) <= to_signed(ext_a_val(i, g - i), DATA_WIDTH);
          else
            act_west(i) <= (others => '0');
          end if;
        end loop;
        for j in 0 to ARRAY_COLS - 1 loop
          if g - j >= 0 and g - j <= k_len - 1 then
            wgt_north(j) <= to_signed(ext_w_val(g - j, j), DATA_WIDTH);
          else
            wgt_north(j) <= (others => '0');
          end if;
        end loop;
        wait until rising_edge(clk);
      end loop;

      -- Drain any remaining pipeline: margin idle cycles (mode still
      -- COMPUTE_OS, inputs zero) before drain, same generous margin as
      -- the original single-K test (more than the minimal ARRAY_COLS
      -- needed, harmless either way).
      act_west <= (others => (others => '0'));
      wgt_north <= (others => (others => '0'));
      for i in 0 to 2 * ARRAY_ROWS loop
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
    report "tb_systolic_array: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_systolic_array FAILED" severity failure;
    else
      report "tb_systolic_array PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
