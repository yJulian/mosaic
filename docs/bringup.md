# Hardware Bring-up

## Status

All RTL is fully verified in simulation (see "Verification" below).

**Real hardware bring-up is fully done**, using the Gowin toolchain
(see "Toolchain note" below for how that came about): built,
SRAM-programmed onto a real Tang Nano 20K, and the entire bring-up
sequence in step 4 passes -- ping, WS round trip, and OS round trip,
both compute modes verified against numpy on real silicon
(`fpga-systolic run --mode ws/os --random --verify` ->
`VERIFY OK: matches numpy` for both). Getting there took finding and
fixing one real bug -- the reset button input, not the compute core --
see "UART bring-up: dead link, found and fixed" below for the full
trail.

## Toolchain note: Gowin EDA, not the original open-source plan

The original plan was a fully open-source flow: yosys+GHDL
(`synth_gowin`) -> `nextpnr-himbaechel` (place&route) -> apycula
`gowin_pack` (bitstream) -> `openFPGALoader`. Chip identity was never
the blocker some earlier notes assumed -- the Tang Nano 20K's real part
is **GW2AR-LV18QN88C8/I7** (device family `GW2A-18C`), confirmed
against Sipeed's own official example repo
(`github.com/sipeed/TangNano-20K-example`), and oss-cad-suite does ship
a `GW2A-18C` chipdb covering it. That open-source flow did reach
bitstream successfully in an earlier session (sane resource counts:
36/40 MULT9X9, ~11,930 placed cells). **It just never got running
end-to-end in this repo's actual Linux dev environment** -- so this
project now uses Gowin's own EDA instead (the free Education tier;
`gw_sh`, a headless Tcl shell, no GUI needed), which is what
`scripts/build.sh`/`scripts/program.sh` actually run. See
`gowin/build.tcl` for the synthesis/P&R/bitstream script and
`scripts/common_gowin.sh` for how the install is located
(`GOWIN_DIR` env var to override auto-detection).

Switching toolchains surfaced two real, worth-knowing findings:

- `constraints/tangnano20k.cst` set `IO_LOC`/`PULL_MODE` on every pin
  but never `IO_TYPE`. Gowin's placer defaults unconstrained pins to
  LVCMOS18 and hard-errors (`CT1136`) because banks 3/6/7 (reset
  button, LEDs, clock) are shared with other 3.3V-locked pins on this
  device. Fixed by adding `IO_TYPE=LVCMOS33` to every `IO_PORT` line,
  matching what Sipeed's own examples (`led/blink_leds`, `uart/`,
  `picorv32/`) set explicitly on every pin. Apycula/nextpnr-himbaechel
  apparently don't enforce this the same way -- it built "successfully"
  without it there -- so this is a plausible contributor to the
  original Linux attempt not working on real hardware even where it
  didn't error: an LVCMOS18-defaulted pin driven from 3.3V-side logic
  (or vice versa) wouldn't necessarily fail synthesis, just behave
  wrong (or risk the hardware) on the board.
- No `.sdc` file exists in this repo, so P&R saw `clk` "determined to
  be a clock but not created" (`TA1132`) and routed the derived
  internal clock net through general routing instead of a dedicated
  clock network (`PR1014`) -- a placement-quality warning, not an
  error, and still an open item. Given the design runs straight off
  the raw 27MHz input (no PLL multiplication), this is very unlikely
  to be a real timing problem, but adding a
  `create_clock -period 37.037 [get_ports clk]` SDC would allow proper
  static timing analysis instead of leaving it implicit.

Programming defaults to SRAM (volatile) via `scripts/program.sh` --
**never flash/persistent** during active bring-up/iteration; `--flash`
exists for an eventual deliberate permanent deployment only. Under the
hood that's `programmer_cli --cable-index 4 --device GW2AR-18C
--operation_index 2 --fsFile <bitstream>` (`6` instead of `2` for
flash). `--cable-index 4` is "USB Debugger A" (the Tang Nano 20K's
onboard FT2232H debugger); `programmer_cli --scan-cables` / `--scan`
confirm a board is attached and its ID matches `GW2AR-18C` /
`0x0000081B` -- more than one FT2232H/JTAG device can show up in
Windows' device list at once (multi-channel chip, not necessarily
multiple boards), so don't assume the first hit is the right one.

## UART bring-up: dead link, found and fixed

First attempt at step 2 below (`fpga-systolic ping`) got nothing back
-- not a CRC error, not a timeout-with-partial-data, zero bytes over
the wire at any baud tried. Structured bisection, each one a separate
minimal bitstream (built via `gowin/build_uart_test.tcl`, SRAM-loaded
between each), narrowest layer first:

1. **`rtl/top/uart_wire_test.vhd`** -- `uart_tx_pin <= uart_rx_pin`
   directly, no clock domain, no FSM at all. Sending arbitrary bytes
   from the host echoed back byte-for-byte. This alone proved the
   pins (69/70), the `IO_TYPE=LVCMOS33` fix above, SRAM programming,
   and the host's COM port identification were all correct -- the bug
   had to be *above* the raw pins.
2. **`rtl/top/uart_echo_test.vhd`** -- real `uart_rx`/`uart_tx` FSMs
   (the actual modules `top.vhd` uses), gated by `clk_reset_gen`'s
   `rst` like the real design. Complete silence, even for single
   bytes with generous gaps -- so the bug was in `uart_rx`/`uart_tx`
   or their reset gating, not the physical link.
3. A variant with `rst` hard-tied to `'0'` (bypassing
   `clk_reset_gen`/`rst_btn_n` entirely, otherwise identical) echoed
   perfectly. This isolated the bug to `clk_reset_gen`/`rst_btn_n`
   specifically.
4. A diagnostic variant echoed back `{rst_btn_n, rst, ...}` instead of
   the received byte, to read the pin's real state over the (now
   confirmed working) link without needing eyes on the board. Result,
   consistently across multiple separate programming runs: `rst_btn_n
   = 0` (permanently "pressed"), so `rst = 1` (permanently asserted) --
   the whole design was stuck in reset forever. The heartbeat LED
   would have kept blinking regardless (it isn't gated by `rst` by
   design), so it could **not** have caught this on its own.

Pin 88 (`rst_btn_n`) is Sipeed's "KEY1" button, but it's also the
chip's `MODE0` boot-strap pin (confirmed against the official
schematic, `Tang_Nano_20K_3921_Schematics` rev 1.22) with a real
330ohm hardware pull-up to 3.3V and the switch to GND -- so it should
read high (released) by default, same assumption this project already
had. Why it read permanently low on this board wasn't pinned down
further (possibly a fault on this specific unit, possibly this
MODE-shared pin not behaving as plain GPIO post-configuration on this
device) -- not worth chasing further when the fix is straightforward
and strictly safer either way: **`clk_reset_gen` no longer takes any
external pin.** It's now a pure internal power-on-reset (a short
counter, asserted for the first 15 cycles after configuration, then
released permanently) -- see `rtl/top/clk_reset_gen.vhd`. `top.vhd`
lost the `rst_btn_n` port entirely, and the pin is unconstrained in
`constraints/tangnano20k.cst` now. `sim/tb_top.vhd` and the two
surviving debug bitstreams (`uart_wire_test.vhd`, `uart_echo_test.vhd`,
kept as reusable bring-up aids) were updated to match. Full sim suite
re-run after the change: `tb_top` still 90/90 checks passing.

With that fix, `fpga-systolic ping -p COM11 -b 1500000` against the
real `top.vhd` bitstream returns `fw_version=1 rows=6 cols=6 dtype=0`
-- the full `uart_rx -> rx_fifo -> cmd_processor -> tx_fifo -> uart_tx`
chain confirmed working on real hardware.

## Step 1: build the bitstream

```bash
scripts/build.sh          # -> gowin/proj/mosaic/impl/pnr/mosaic.fs
```

Runs synthesis, place&route, and bitstream packing in one headless
`gw_sh` call (see `gowin/build.tcl`). Needs a Gowin EDA install --
auto-detected, or set `GOWIN_DIR` (see `scripts/common_gowin.sh`).
Per-stage reports (resource utilization, timing, pins) land under
`gowin/proj/mosaic/impl/{gwsynthesis,pnr}/*.rpt.html`.

## Step 2: pin constraints -- confirm before powering anything

`constraints/tangnano20k.cst` is now cross-checked against Sipeed's
official example repo (`led/blink_leds`, `uart/`, `picorv32/` under
`github.com/sipeed/TangNano-20K-example`), not just community
references -- this caught a real bug where `uart_rx_pin`/`uart_tx_pin`
were assigned to pins 18/17 (two of the onboard LEDs) instead of the
real UART pins 70/69. Current assignments:
- `clk` = 4 (27MHz onboard oscillator)
- `uart_rx_pin` = 70, `uart_tx_pin` = 69
- `led_n[0..5]` = 15, 16, 17, 18, 19, 20

`led_n`'s six bits are all debug outputs, not just the heartbeat -- see
`rtl/top/top.vhd`'s "Status LEDs" section:
- `led_n[0]`: ~1.6Hz heartbeat (alive check, not gated by `rst`)
- `led_n[1]`: `array_busy`, raw (a WS/OS compute is only tens of cycles,
  microseconds at 27MHz -- this blinks far too fast to see by eye; it's
  there for a logic analyzer, not a human)
- `led_n[2]`: `array_done`, latches until the next `start_compute_*`
- `led_n[3..5]`: `array_busy`/host-write/host-read, each passed through
  `rtl/common/pulse_stretch.vhd` (200ms minimum-on-time, retriggerable)
  so a single compute or scratchpad access is actually visible: `[3]`
  flashes on any compute, `[4]` on `WRITE_WEIGHTS`/`WRITE_ACTIVATIONS`,
  `[5]` on `READ_RESULT` byte reads.

(Pin 88, Sipeed's "KEY1"/chip `MODE0`, is intentionally unused -- see
"UART bring-up" above for why the design no longer takes an external
reset input at all.)

Still worth a final sanity check before the first program attempt:
- `led_n` polarity (assumed active-low, matching other Tang Nano
  boards' convention; wrong polarity just means LEDs read inverted)

None of this is load-bearing for the compute core's correctness --
only for whether you can see status LEDs or talk over UART at all.

## Step 3: program

```bash
scripts/program.sh                  # SRAM, volatile (default)
scripts/program.sh --flash          # embFlash, persistent
```

SRAM by default -- see the toolchain note above for why. Scans for a
cable and confirms the device ID before programming; pass an explicit
path (`scripts/program.sh /path/to/other.fs`) to program a bitstream
other than the default build output.

## Step 4: bring-up sequence

Do these **in order** -- each one isolates a different layer, so a
failure at step N with steps <N working narrows down the problem a lot.

1. **Heartbeat LED**: after programming, `led_n[0]` (pin 15, per the
   CST above) should blink at roughly 1.6Hz
   (`heartbeat_ctr(23)` toggling at 27MHz/2^24). This alone confirms
   the bitstream loaded, the clock is running, and the CST's clock pin
   is right -- independent of anything UART/compute related. Note it
   is *not* gated by `rst`, by design, so it can't substitute for step
   2 below (see "UART bring-up" above for exactly this gap).
2. **UART link only**: from the host, run
   `fpga-systolic ping -p <port> -b 1500000` (see `python/README`-equivalent
   usage in `docs/protocol.md`). A working `PONG` response confirms
   the UART pins, baud rate, and the whole `uart_rx -> rx_fifo ->
   cmd_processor -> tx_fifo -> uart_tx` chain. **Confirmed working** on
   real hardware (Tang Nano 20K via the Gowin flow above) --
   `fw_version=1 rows=6 cols=6 dtype=0`. If this hangs or times out,
   suspect the UART pin assignment, baud mismatch, or the reset chain
   before suspecting the compute core -- none of that logic is
   exercised yet.
3. **Weight-stationary round trip**: `fpga-systolic run -p <port>
   --mode ws --random --verify`. Confirms the full compute pipeline:
   staging, array load, WS compute, drain/writeback, result readback,
   compared against a numpy reference. **Confirmed working** on real
   hardware -- `VERIFY OK: matches numpy`.
4. **Output-stationary round trip**: same with `--mode os`. Should
   produce identical results to WS for the same inputs (both compute
   the same matmul). **Confirmed working** on real hardware too --
   `VERIFY OK: matches numpy`.
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
- Host-to-board round-trip latency over UART is dominated by USB/OS
  overhead, not the UART bit rate itself: a full WS/OS compute round
  trip (`ping`, `run --mode ws`, etc.) measured ~85ms on real hardware
  even though the actual compute core only takes ~250 clock cycles
  (~9us at 27MHz) and raw byte transfer at 1.5MBaud is sub-millisecond.
  Traced to a consistent ~16-17ms-per-transaction floor that survived
  both a registry-level and a live D2XX-API-level FTDI "Latency Timer"
  fix (confirmed set to 1ms at the driver, made no difference) and
  isn't explained by USB Selective Suspend (already disabled on this
  machine's power plan) -- likely a deeper Windows USB-host-stack
  characteristic specific to this dev machine. Not chased further: not
  a correctness issue, and ~85ms/round-trip is fine for bring-up and
  validation. If throughput ever matters, worth trying a different USB
  port/cable, or Linux's `ftdi_sio` `low_latency` sysfs flag, which
  tends to actually take effect (unlike this Windows session).

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

Both of the above run in CI on every push/PR (`.github/workflows/ci.yml`)
-- synthesis/P&R/programming don't, since those need the licensed Gowin
toolchain and a real board, neither of which a generic CI runner has.
