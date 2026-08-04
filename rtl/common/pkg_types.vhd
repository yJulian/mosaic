library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Shared array/data-width constants and interconnect types for the
-- 6x6 systolic array accelerator. Single source of truth for array
-- dimensions so testbenches and RTL never drift apart.
package pkg_types is

  constant ARRAY_ROWS  : natural := 6;
  constant ARRAY_COLS  : natural := 6;

  constant DATA_WIDTH  : natural := 8;   -- int8 activations/weights
  constant ACC_WIDTH   : natural := 32;  -- int32 accumulator

  subtype data_t is signed(DATA_WIDTH - 1 downto 0);
  subtype acc_t  is signed(ACC_WIDTH - 1 downto 0);

  -- West-edge activation inputs, one lane per PE row.
  type act_vec_t is array (0 to ARRAY_ROWS - 1) of data_t;
  -- North-edge weight inputs, one lane per PE column.
  type wgt_vec_t is array (0 to ARRAY_COLS - 1) of data_t;
  -- South-edge outputs (partial sums in WS mode, drained accumulators
  -- in OS mode), one lane per PE column.
  type psum_vec_t is array (0 to ARRAY_COLS - 1) of acc_t;

  -- East-edge / activation pass-through matrix used by the array-level
  -- testbench to observe every horizontal link, and internally between
  -- adjacent PE columns.
  type act_matrix_t is array (0 to ARRAY_ROWS - 1, 0 to ARRAY_COLS) of data_t;
  -- North/south partial-sum matrix used between adjacent PE rows (WS psum
  -- path and OS drain path), (ROWS+1) x COLS links.
  type vert_matrix_t is array (0 to ARRAY_ROWS, 0 to ARRAY_COLS - 1) of acc_t;
  -- North/south weight matrix used between adjacent PE rows (LOAD_WEIGHT
  -- broadcast path and OS weight pass-through), (ROWS+1) x COLS links.
  type vert_data_matrix_t is array (0 to ARRAY_ROWS, 0 to ARRAY_COLS - 1) of data_t;

  -- PE operating mode, shared between pe.vhd, array_ctrl.vhd and their TBs.
  type pe_mode_t is (
    PE_IDLE,        -- hold state, no register updates
    PE_LOAD_WEIGHT, -- broadcast+capture weight columns (WS preload)
    PE_COMPUTE_WS,  -- weight-stationary compute
    PE_COMPUTE_OS,  -- output-stationary compute (both operands stream)
    PE_DRAIN_OS     -- columnar parallel shift-out of OS accumulators
  );

end package pkg_types;
