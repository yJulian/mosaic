library ieee;
use ieee.std_logic_1164.all;
use work.pkg_types.all;

-- 6x6 grid of PEs wired into a systolic network:
--   activations flow west -> east  (act_west in,  act_east out)
--   weights     flow north -> south (wgt_north in, wgt_south out)
--   partial sums flow north -> south (psum_north in, psum_south out)
-- mode/os_clear/load_counter are broadcast identically to every PE; each
-- PE only differs by its static ROW/COL generic.
entity systolic_array is
  port (
    clk : in std_logic;
    rst : in std_logic;

    mode         : in pe_mode_t;
    os_clear     : in std_logic;
    load_counter : in natural range 0 to 2 * ARRAY_ROWS;

    act_west   : in act_vec_t;
    wgt_north  : in wgt_vec_t;
    psum_north : in psum_vec_t;

    act_east   : out act_vec_t;
    wgt_south  : out wgt_vec_t;
    psum_south : out psum_vec_t;

    debug_weight : out data_t;
    debug_accum  : out acc_t;
    debug_row    : in natural range 0 to ARRAY_ROWS - 1;
    debug_col    : in natural range 0 to ARRAY_COLS - 1
  );
end entity systolic_array;

architecture rtl of systolic_array is
  signal act_link  : act_matrix_t;
  signal wgt_link  : vert_data_matrix_t;
  signal psum_link : vert_matrix_t;

  type debug_weight_arr_t is array (0 to ARRAY_ROWS - 1, 0 to ARRAY_COLS - 1) of data_t;
  type debug_accum_arr_t is array (0 to ARRAY_ROWS - 1, 0 to ARRAY_COLS - 1) of acc_t;
  signal debug_weight_arr : debug_weight_arr_t;
  signal debug_accum_arr  : debug_accum_arr_t;
begin

  -- West / east boundary
  gen_west : for r in 0 to ARRAY_ROWS - 1 generate
    act_link(r, 0) <= act_west(r);
    act_east(r) <= act_link(r, ARRAY_COLS);
  end generate;

  -- North / south boundary
  gen_north : for c in 0 to ARRAY_COLS - 1 generate
    wgt_link(0, c) <= wgt_north(c);
    wgt_south(c) <= wgt_link(ARRAY_ROWS, c);
    psum_link(0, c) <= psum_north(c);
    psum_south(c) <= psum_link(ARRAY_ROWS, c);
  end generate;

  gen_rows : for r in 0 to ARRAY_ROWS - 1 generate
    gen_cols : for c in 0 to ARRAY_COLS - 1 generate
      pe_inst : entity work.pe
        generic map (ROW => r, COL => c)
        port map (
          clk => clk, rst => rst,
          mode => mode, os_clear => os_clear, load_counter => load_counter,
          act_in  => act_link(r, c),
          wgt_in  => wgt_link(r, c),
          psum_in => psum_link(r, c),
          act_out  => act_link(r, c + 1),
          wgt_out  => wgt_link(r + 1, c),
          psum_out => psum_link(r + 1, c),
          debug_weight => debug_weight_arr(r, c),
          debug_accum  => debug_accum_arr(r, c)
        );
    end generate;
  end generate;

  debug_weight <= debug_weight_arr(debug_row, debug_col);
  debug_accum  <= debug_accum_arr(debug_row, debug_col);

end architecture rtl;
