# Hardware Bring-up

## Status

All RTL is fully verified in simulation (see "Verification" below).
The full open-source build flow -- `scripts/build.sh`, which runs
`synth_gowin` (yosys+GHDL) -> `nextpnr-himbaechel` (place&route) ->
apycula `gowin_pack` (bitstream) -- has been run end-to-end against the
real design (resource counts sane: 36/40 MULT9X9, ~11,930 placed
cells) and produces a `.fs` file. **Nothing below this point has been
run on a physical board** -- this environment has no board attached.
Treat the bring-up sequence in step 3 as a documented plan, not a
confirmed procedure; everything up through bitstream generation *is*
confirmed.

## Toolchain note: no Gowin EDA needed

An earlier version of this project believed Gowin's proprietary EDA
was required, because it checked chipdb availability for the wrong
chip (GW1NSR-18C). The Tang Nano 20K actually uses **GW2AR-LV18QN88C8/I7**
(device family `GW2A-18C`), confirmed against Sipeed's own official
example repo (`github.com/sipeed/TangNano-20K-example`). This
oss-cad-suite build ships a `GW2A-18C` chipdb in both
`nextpnr-himbaechel` and `apycula`, which covers the GW2AR-18C
variant's packages -- so the entire flow is open-source, no proprietary
tool involved. See `docs/architecture.md` and `scripts/common.sh` for
how this was verified.

## Step 1: build the bitstream

```bash
scripts/build.sh          # -> build/top.fs
```

Runs synthesis, place&route, and bitstream packing in one go (see
`scripts/build.sh` for the individual `yosys`/`nextpnr-himbaechel`/
`gowin_pack` invocations if you need to run a step standalone, e.g. to
inspect the post-P&R resource utilization report from
`nextpnr-himbaechel`'s own log output).

## Step 2: pin constraints -- confirm before powering anything

`constraints/tangnano20k.cst` is now cross-checked against Sipeed's
official example repo (`led/blink_leds`, `uart/`, `picorv32/` under
`github.com/sipeed/TangNano-20K-example`), not just community
references -- this caught a real bug where `uart_rx_pin`/`uart_tx_pin`
were assigned to pins 18/17 (two of the onboard LEDs) instead of the
real UART pins 70/69. Current assignments:
- `clk` = 4 (27MHz onboard oscillator)
- `rst_btn_n` = 88
- `uart_rx_pin` = 70, `uart_tx_pin` = 69
- `led_n[0..5]` = 15, 16, 17, 18, 19, 20

Still worth a final sanity check before the first program attempt:
- `led_n` polarity (assumed active-low, matching other Tang Nano
  boards' convention; wrong polarity just means LEDs read inverted)

None of this is load-bearing for the compute core's correctness --
only for whether you can see status LEDs or talk over UART at all.

## Step 3: program

```bash
scripts/program.sh build/top.fs           # SRAM, volatile
scripts/program.sh build/top.fs --flash   # flash, persistent
```

## Step 4: bring-up sequence

Do these **in order** -- each one isolates a different layer, so a
failure at step N with steps <N working narrows down the problem a lot.

1. **Heartbeat LED**: after programming, `led_n[0]` (pin 15, per the
   CST above) should blink at roughly 1.6Hz
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
  experimental upstream. It's what this project's whole open-source
  build flow relies on for P&R (see the toolchain note above) -- placement
  succeeded on the full design in this session, but timing closure /
  routing-corner behavior on real silicon hasn't been checked yet.

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
