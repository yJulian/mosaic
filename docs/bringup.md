# Hardware Bring-up

## Status

All RTL is fully verified in simulation (see "Verification" below) and
via `scripts/build.sh`'s synthesis-only run (resource counts sane,
36/40 MULT9X9, ~11-14K LUT-equivalent cells -- see `docs/architecture.md`
for why that doesn't fit a Tang Nano 9K but should comfortably fit the
Tang Nano 20K this project targets). **Nothing below this point has
been run on real hardware or in Gowin EDA** -- this environment has
neither a physical board nor the proprietary Gowin EDA tool installed.
Treat every step here as a documented plan, not a confirmed procedure.

## Why Gowin EDA is needed at all

This oss-cad-suite build has no chipdb for GW1NSR-18C (Tang Nano 20K)
in either `nextpnr-himbaechel` or `apycula` (confirmed empirically --
see `docs/architecture.md`). `scripts/build.sh` still runs
`synth_gowin` successfully (it's device-family-generic), which is
useful for linting and resource estimates, but place&route and
bitstream packing for this specific device need Gowin's own tool.
`openFPGALoader` itself is **not** chipdb-limited, so it can still
flash whatever `.fs` Gowin EDA produces.

## Step 1: Gowin EDA project setup

1. Install Gowin EDA (free registration required, Sipeed/Gowin's own
   download). Not installed in this environment -- do this on your
   own machine.
2. Create a new FPGA project targeting **GW1NSR-LV18QN88PC6/I5**
   (Tang Nano 20K).
3. Add all files under `rtl/` to the project as VHDL sources (Gowin
   EDA's synthesizer reads VHDL directly; no need to route through
   yosys for this path). Set `top` (`rtl/top/top.vhd`) as the top-level
   module.
4. Add `constraints/tangnano20k.cst` as the project's physical
   constraints file.
5. Run Synthesize, then Place & Route, from Gowin EDA's own flow.
   Check the resulting resource utilization report -- if it's still
   over budget (unexpected, given the 9K-vs-20K capacity gap, but
   worth confirming), see `docs/architecture.md`'s notes on what was
   already tried (multiplier sharing) and what wasn't worth it
   (register merging made things worse, not better).
6. Generate the bitstream (`.fs` file).

## Step 2: pin constraints -- confirm before powering anything

`constraints/tangnano20k.cst` is flagged internally as **lower
confidence** than a typical verified pinout: it reflects commonly-
referenced community Tang Nano 20K pin numbers, not something
cross-checked against the official Sipeed schematic in this session
(unlike the original Tang Nano 9K CST, which was superseded when the
board target changed). Before the first program attempt, check every
`IO_LOC` in that file against Sipeed's official Tang Nano 20K
pinout/schematic, especially:
- `clk` (must be the 27MHz onboard oscillator pin)
- `uart_rx_pin`/`uart_tx_pin` direction (easy to swap by mistake --
  wrong pin numbers here just mean "no bytes arrive," not damage)
- `led_n` polarity (assumed active-low, matching other Tang Nano
  boards' convention; wrong polarity just means LEDs read inverted)

None of this is load-bearing for the compute core's correctness --
only for whether you can see status LEDs or talk over UART at all.

## Step 3: program

```bash
scripts/program.sh /path/to/gowin_eda_output.fs         # SRAM, volatile
scripts/program.sh /path/to/gowin_eda_output.fs --flash  # flash, persistent
```

## Step 4: bring-up sequence

Do these **in order** -- each one isolates a different layer, so a
failure at step N with steps <N working narrows down the problem a lot.

1. **Heartbeat LED**: after programming, `led_n[0]` (per the CST above,
   pending pin confirmation) should blink at roughly 1.6Hz
   (`heartbeat_ctr(23)` toggling at 27MHz/2^24). This alone confirms
   the bitstream loaded, the clock is running, and the CST's clock pin
   is right -- independent of anything UART/compute related.
2. **UART link only**: from the host, run
   `fpga-systolic ping -p <port> -b 1500000` (see `python/README`-equivalent
   usage in `docs/protocol.md`). A working `PONG` response confirms
   the UART pins, baud rate, and the whole `uart_rx -> rx_fifo ->
   cmd_processor -> tx_fifo -> uart_tx` chain. If this hangs or times
   out, suspect the UART pin assignment or baud mismatch before
   suspecting the compute core -- none of that logic is exercised yet.
3. **Weight-stationary round trip**: `fpga-systolic run -p <port>
   --mode ws --random --verify`. Confirms the full compute pipeline:
   staging, array load, WS compute, drain/writeback, result readback,
   compared against a numpy reference.
4. **Output-stationary round trip**: same with `--mode os`. Should
   produce identical results to WS for the same inputs (both compute
   the same matmul).
5. **Debug readback**: `fpga-systolic debug-pe -p <port> --row 2 --col 3`
   mid- or post-compute, to sanity-check individual PE register values
   directly -- useful if 3 or 4 above fail and you need to see inside
   the array rather than just its final output.
6. **Baud stretch goal**: once 1.5 MBaud is solid, try `-b 3000000`
   (also an exact 27MHz divisor). Not required for correctness, purely
   a throughput experiment -- revert to 1.5 MBaud if it's flaky.

## Known risks / open items (carried over from planning, still open)

- Exact max reliable UART baud on the real USB-UART bridge chip is
  unverified -- start at 1.5 MBaud.
- BSRAM inference (`DPB` cells) was confirmed for the scratchpad's
  coding pattern via synthesis cell-count, but re-check if that
  module's RTL ever changes (`grep DPB` in a fresh `synth_gowin` run).
- DSP inference (`MULT9X9`, one per PE) was confirmed via synthesis
  cell-count (36/40) after the multiplier-sharing fix -- re-check
  after any change to `rtl/pe/pe.vhd`'s multiply expression.
- CRC-8 (poly 0x07) is a deliberate simplicity trade for a short,
  low-noise, wired link; upgrade to CRC-16 if bring-up shows real
  corruption (contained change, see `docs/protocol.md`).
- `nextpnr-himbaechel`'s Gowin backend is explicitly marked
  experimental upstream -- moot for the final device now (Gowin EDA
  handles P&R for GW1NSR-18C), but relevant if this project ever adds
  a secondary Tang Nano 9K/4K build target through the open-source
  path.

## Verification (what's already confirmed, without hardware)

Run the full simulation suite: `scripts/sim_all.sh` (or `make sim-all`).
Covers, in dependency order: PE MAC/mode logic, array interconnect
timing (WS/OS/DRAIN, including the two empirically-discovered timing
bugs described in `docs/architecture.md`), the array controller FSM,
the BSRAM scratchpad, the full core datapath end-to-end (staging
through writeback) for both WS and OS against a golden matmul, CRC-8
against independently-computed Python vectors, UART TX/RX loopback
(including back-to-back framing), the generic FIFO, the full UART
protocol parser/dispatcher (39 checks, including the busy/NACK path
and the seven distinct latency/multi-driver bugs found and fixed while
building it -- see inline comments in `rtl/ctrl/cmd_processor.vhd`),
and finally the complete chip (`tb_top.vhd`, 90 checks) driven purely
over simulated UART exactly as the real Python host driver will.

Also run the host-only protocol tests (no hardware needed):
```bash
cd python && .venv/bin/pytest tests/ -v
```
