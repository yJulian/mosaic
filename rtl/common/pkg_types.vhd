library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Shared array/data-width constants and interconnect types for the
-- 6x6 systolic array accelerator. Single source of truth for array
-- dimensions so testbenches and RTL never drift apart.
package pkg_types is

  constant ARRAY_ROWS  : natural := 6;
  constant ARRAY_COLS  : natural := 6;

  -- Max contraction (K) length for a single OS (output-stationary)
  -- compute call. M and N stay physically fixed at ARRAY_ROWS/ARRAY_COLS
  -- (the array's own size); K is purely time-streamed in OS mode (see
  -- rtl/array/array_ctrl.vhd's STAGE_A/S_COMPUTE_OS), so it can exceed 6
  -- within a single hardware call, up to this compile-time upper bound.
  -- WS (weight-stationary) mode does not use this at all -- K is
  -- physically bound to ARRAY_ROWS there (stationary weight storage per
  -- PE), unchanged. Chosen conservatively (not 64+): each activation-feed
  -- lane's combinational select mux grows from a 6:1 to an OS_K_MAX:1 mux,
  -- which dominates LUT cost more than raw register count -- confirm via
  -- an actual Gowin utilization report before hardware bring-up, don't
  -- assume this fits just because it fits on paper. (Confirmed
  -- empirically: OS_K_MAX=32 synthesized to 87% logic / 89% CLS
  -- utilization on the Tang Nano 20K -- technically fits but too tight
  -- for comfort, so dialed back to 16 per this file's own guidance.)
  constant OS_K_MAX : natural := 16;

  constant DATA_WIDTH  : natural := 8;   -- int8 activations/weights
  constant ACC_WIDTH   : natural := 32;  -- int32 accumulator

  subtype data_t is signed(DATA_WIDTH - 1 downto 0);
  subtype acc_t  is signed(ACC_WIDTH - 1 downto 0);

  -- Shared upper bound for array_ctrl/skew_feeder/ws_weight_loader's
  -- phase_cycle ports -- must cover the OS feed phase's worst case
  -- (ARRAY_ROWS+ARRAY_COLS+OS_K_MAX-1, see array_ctrl.vhd). A single
  -- source of truth here is deliberate: three independent hardcoded
  -- "0 to 31" declarations previously silently overflowed once K>21,
  -- freezing the feeders on a stale value with no error -- caught only by
  -- a design review tracing actual signal widths, not by inspection.
  subtype phase_cycle_t is natural range 0 to ARRAY_ROWS + ARRAY_COLS + OS_K_MAX - 1;

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
