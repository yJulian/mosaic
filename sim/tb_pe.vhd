library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_types.all;

entity tb_pe is
end entity tb_pe;

architecture sim of tb_pe is
  constant CLK_PERIOD : time := 10 ns;
  constant TEST_ROW    : natural := 2;
  constant TEST_COL    : natural := 1;

  signal clk          : std_logic := '0';
  signal rst          : std_logic := '1';
  signal mode         : pe_mode_t := PE_IDLE;
  signal os_clear     : std_logic := '0';
  signal load_counter : natural range 0 to 2 * ARRAY_ROWS := 0;
  signal act_in, wgt_in : data_t := (others => '0');
  signal psum_in       : acc_t := (others => '0');
  signal act_out, wgt_out : data_t;
  signal psum_out       : acc_t;
  signal debug_weight   : data_t;
  signal debug_accum    : acc_t;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  dut : entity work.pe
    generic map (ROW => TEST_ROW, COL => TEST_COL)
    port map (
      clk => clk, rst => rst,
      mode => mode, os_clear => os_clear, load_counter => load_counter,
      act_in => act_in, wgt_in => wgt_in, psum_in => psum_in,
      act_out => act_out, wgt_out => wgt_out, psum_out => psum_out,
      debug_weight => debug_weight, debug_accum => debug_accum
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
  begin
    rst <= '1'; mode <= PE_IDLE;
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    ------------------------------------------------------------------
    -- Test 1: WS weight load. TEST_ROW=2 -> capture at load_counter=4.
    ------------------------------------------------------------------
    mode <= PE_LOAD_WEIGHT;
    for t in 0 to 2 * ARRAY_ROWS loop
      load_counter <= t;
      wgt_in <= to_signed(t * 10, DATA_WIDTH);
      wait until rising_edge(clk);
    end loop;
    wait for 1 ns;
    check_data(debug_weight, 40, "WS weight capture at load_counter=2*ROW");

    ------------------------------------------------------------------
    -- Test 2: COMPUTE_WS MAC + pass-through.
    ------------------------------------------------------------------
    mode <= PE_COMPUTE_WS;
    act_in <= to_signed(3, DATA_WIDTH);
    psum_in <= to_signed(100, ACC_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(psum_out, 220, "WS MAC: 100 + 3*40");
    check_data(act_out, 3, "WS activation pass-through");

    act_in <= to_signed(-5, DATA_WIDTH);
    psum_in <= to_signed(50, ACC_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(psum_out, -150, "WS MAC: 50 + (-5)*40");

    ------------------------------------------------------------------
    -- Test 3: COMPUTE_OS accumulate + pass-through both directions.
    ------------------------------------------------------------------
    mode <= PE_COMPUTE_OS;
    os_clear <= '1';
    act_in <= to_signed(99, DATA_WIDTH);
    wgt_in <= to_signed(99, DATA_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(debug_accum, 0, "OS clear");

    os_clear <= '0';
    act_in <= to_signed(2, DATA_WIDTH);
    wgt_in <= to_signed(3, DATA_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(debug_accum, 6, "OS accum after pair (2,3)");
    check_data(act_out, 2, "OS act pass-through");
    check_data(wgt_out, 3, "OS wgt pass-through");

    act_in <= to_signed(4, DATA_WIDTH);
    wgt_in <= to_signed(5, DATA_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(debug_accum, 26, "OS accum after pair (4,5)");

    act_in <= to_signed(6, DATA_WIDTH);
    wgt_in <= to_signed(7, DATA_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(debug_accum, 68, "OS accum after pair (6,7)");

    ------------------------------------------------------------------
    -- Test 4: DRAIN_OS columnar shift.
    ------------------------------------------------------------------
    mode <= PE_DRAIN_OS;
    psum_in <= to_signed(999, ACC_WIDTH);
    wait for 1 ns; -- same cycle: mode mux settles, no edge yet
    check_acc(psum_out, 68, "DRAIN shift-out: old accum visible before edge");

    wait until rising_edge(clk);
    wait for 1 ns;
    check_acc(debug_accum, 999, "DRAIN shift-in: new value latched after edge");
    check_acc(psum_out, 999, "DRAIN shift-out: newly shifted value now visible");

    ------------------------------------------------------------------
    report "tb_pe: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_pe FAILED" severity failure;
    else
      report "tb_pe PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
