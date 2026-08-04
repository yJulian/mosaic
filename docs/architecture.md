# Architecture

## Overview

A 6x6 systolic array of int8x8->int32 MAC processing elements (PEs),
switchable between two GEMM dataflows (weight-stationary and
output-stationary), fed from an on-chip BSRAM scratchpad, controlled
over a framed UART protocol from a Python host.

```
Host (Python) --UART--> uart_rx --> rx_fifo --> cmd_processor
                                                      |
                            +-------------------------+-------------------------+
                            |                         |                         |
                       array_ctrl <----phase_cycle----+                         |
                            |  (mode/os_clear/load_counter)                     |
                            v                                                   |
                     systolic_array (6x6 PEs) <---- ws_weight_loader            |
                            |                  <---- skew_feeder                |
                            v                                                   |
                     result_drainer                                            |
                            |                                                  |
                            v                                                  v
                       scratchpad (BSRAM, port-muxed: array_ctrl <-> host) <----+
                            |
                            v
              cmd_processor --> tx_fifo --> uart_tx --UART--> Host
```

## Dataflow modes

Both modes compute `C = A @ W` for 6x6 int8 matrices `A` (activations)
and `W` (weights), accumulating in int32, no saturation.

### Weight-stationary (WS)

- **Load**: `W` is broadcast into the array from the north edge, one
  row of `W` per cycle, over `ARRAY_ROWS` cycles. Each PE's static
  `ROW` generic determines when it captures: because the array only
  has neighbor-to-neighbor links, a value fed at global cycle `t`
  reaches physical row `r` after `r` register hops (cycle `t+r`). PE
  row `r` holds `W[r][*]`, fed at `t=r`, so it arrives at cycle `2*r`
  -- that's the capture condition (`load_counter = 2*ROW`).
- **Compute**: activations stream west->east, skewed by row (`row k`
  fed with a `k`-cycle delay relative to row 0 -- same skew technique
  as OS, just applied to one operand instead of two). Partial sums
  flow north->south, each PE adding `act*weight_stat` to the incoming
  sum. Output `C(m,c)` becomes valid at `psum_south(c)` at local cycle
  `g = m + ARRAY_ROWS + c - 1` (empirically confirmed via simulation,
  see `sim/tb_systolic_array.vhd`).
- Both the load and compute cycle counts needed one more cycle than a
  naive count suggested -- confirmed by simulation catching the last
  row/column's output arriving one cycle later than initially assumed.

### Output-stationary (OS)

- Both operands stream in simultaneously, skewed by their own array
  position: row `i`'s activation feed starts `i` cycles late, column
  `j`'s weight feed starts `j` cycles late. Both operands for
  contraction index `t` then arrive at PE(i,j) at the same cycle
  `i+j+t`, by construction (classic Kung/Leiserson output-stationary
  skew). Each PE accumulates `act*wgt` locally every cycle it has
  valid data.
- One dedicated `os_clear` cycle zeroes every PE's accumulator before
  real data starts flowing (needed since the first cycle's fed data
  can't be distinguished from "just cleared" otherwise).
- The array needs a **propagation margin** after the last operand is
  fed: the last value for PE(ROWS-1,COLS-1) doesn't finish arriving
  and registering until `(ROWS-1)+(COLS-1)+(ROWS-1)+1` cycles after
  the feed window closes. Getting this wrong was a real bug caught by
  simulation (`tb_array_ctrl` failed on the "far" PEs specifically
  until the margin was added) -- see `rtl/array/array_ctrl.vhd`.
- **Drain**: each PE outputs its accumulator south while loading in
  whatever its north neighbor holds, turning each column into a
  6-deep shift register. One combinational read (row `ROWS-1`) plus
  `ROWS-1` shift edges reads out all 6 rows, bottom-to-top, in exactly
  `ARRAY_ROWS` cycles, all 6 columns in parallel.

### Staging / writeback

Neither dataflow can feed the array directly from the BSRAM scratchpad
during the hot loop: OS's steady state needs up to 6 different bytes
(one per row/column) in the same cycle, and WS's rolling output can
produce up to 6 results in the same cycle -- far more than a
single-port byte-wide BRAM can sustain. So `array_ctrl` adds two
bracketing phases:

- **STAGE_W / STAGE_A**: burst-copy the 36-byte weight/activation
  regions out of the scratchpad into `ws_weight_loader` / `skew_feeder`'s
  own local 36-byte register files (fast, arbitrary-access, no BRAM
  read latency) before compute starts.
- **WRITEBACK**: `result_drainer` captures every emerging result into
  its own local 36x32-bit register file during COMPUTE_WS/DRAIN_OS,
  then burst-writes all 144 bytes out to the scratchpad's result
  region afterward, one byte per cycle.

## Toolchain

Everything through simulation and synthesis-for-linting works with the
installed oss-cad-suite (yosys+GHDL plugin, GHDL, nextpnr-himbaechel,
gowin_pack, openFPGALoader). Two toolchain-specific facts, confirmed
empirically in this environment, not assumed:

- Signed `a(7 downto 0) * b(7 downto 0)` in VHDL synthesizes to a
  `MULT9X9` Gowin DSP cell automatically via `synth_gowin` -- but only
  if there is exactly **one** multiply expression per PE in the
  source. The first PE design had two separate `act_in * X` multiply
  expressions (one per compute-mode branch, functionally mutually
  exclusive but textually distinct), and synth_gowin instantiated a
  *separate* MULT9X9 for each -- 72 total against a 40-cell device
  budget. Fixed by computing one shared `mult_result <= act_in * mult_b`
  signal and using it in both branches (see `rtl/pe/pe.vhd`).
- A VHDL array read/written inside a single clocked process with a
  registered read infers Gowin `DPB`/BSRAM cells reliably (confirmed:
  `rtl/mem/bram_sdp.vhd`'s pattern maps a 39936-byte array to exactly
  20 DPB cells, matching the planned memory map).

### Target device capacity (important finding)

The full design (36 PEs + 39KB scratchpad + UART/protocol stack)
synthesizes to roughly 11,000-14,000 LUT-equivalent cells and 36
MULT9X9 DSP cells. This **does not fit** a Tang Nano 9K (GW1N-9C,
8640 LUT4, 40 MULT9X9 max as 2x MULT9X9-per-MULT18X18) -- confirmed by
an actual `nextpnr-himbaechel` run reporting 166% LUT4 utilization.
Merging the PE's two 32-bit registers into one was tried as an area
optimization and **made LUT usage worse**, not better (a wider
next-state select mux for one register cost more than the two simpler
registers saved) -- reverted.

The project therefore targets the originally-intended **Tang Nano 20K**
(GW1NSR-LV18QN88PC6/I5), which has a substantially larger fabric. This
oss-cad-suite build has no chipdb for GW1NSR-18C in either
nextpnr-himbaechel or apycula, so place&route and bitstream packing
for that exact device aren't possible with this open-source toolchain
right now -- `synth_gowin` itself is device-family-generic and still
works for linting/resource estimates, but the final P&R+pack step
needs Gowin's free, proprietary EDA tool. See `docs/bringup.md` for
the exact hybrid-flow steps.

## Memory map

See `docs/memory_map.md`.

## Protocol

See `docs/protocol.md`.
