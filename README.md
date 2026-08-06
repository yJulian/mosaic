# MOSAIC

**M**atrix **O**perations, **S**ystolic **A**rray, **I**nterchangeable **C**ompute

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A 6x6 int8x8->int32 systolic array accelerator for the Sipeed Tang Nano
20K, switchable between weight-stationary and output-stationary GEMM
dataflows, controlled over a framed UART protocol from a Python host.
Built end-to-end with the open-source `oss-cad-suite` toolchain --
yosys + GHDL for synthesis, `nextpnr-himbaechel` for place&route,
apycula's `gowin_pack` for the bitstream, `openFPGALoader` to flash it.
No proprietary tools involved (see [Status](#status) below).

```mermaid
flowchart LR
    CLI["Python host<br/>fpga-systolic CLI"]

    subgraph FPGA["Tang Nano 20K"]
        direction LR
        RX[uart_rx] --> RXF[("rx_fifo")] --> CMD[cmd_processor]
        CMD --> TXF[("tx_fifo")] --> TX[uart_tx]

        CMD <--> AC[array_ctrl]
        AC --> WL[ws_weight_loader]
        AC --> SF[skew_feeder]
        WL --> ARR
        SF --> ARR
        ARR["systolic_array<br/>6x6 PEs"] --> RD[result_drainer]
        RD --> AC

        CMD <-->|host port| SPAD[("scratchpad<br/>BSRAM")]
        AC <-->|stage / writeback port| SPAD
    end

    CLI -->|UART TX| RX
    TX -->|UART RX| CLI
```

*(See [`docs/architecture.md`](docs/architecture.md) for the full
dataflow explanation and an FSM/PE-interconnect diagram.)*

## Status

- **RTL + simulation: complete and fully verified.** Nine testbenches
  cover every module up through a full-chip test (90 checks) driven
  purely over simulated UART, exactly as the real host driver talks to
  it. Run them all with `scripts/sim_all.sh` (or `make sim-all`).
- **Bitstream build: confirmed working, no physical board yet.** The
  full open-source flow (`scripts/build.sh`: synthesis -> place&route
  -> bitstream packing) has been run end-to-end against the real
  design and produces `build/top.fs`. This environment has no Tang
  Nano 20K board attached, so nothing past that point (actually
  flashing and running) has been done for real. See
  [`docs/bringup.md`](docs/bringup.md) for the bring-up sequence.
- The project targets the Tang Nano 20K (GW2AR-LV18QN88C8/I7) rather
  than the smaller Tang Nano 9K: the full design needs more LUTs/DSPs
  than the 9K has. See [`docs/architecture.md`](docs/architecture.md)
  for the resource numbers.

## Repository layout

```
rtl/            VHDL sources
  common/         shared packages (types, protocol constants, memory map)
  pe/             single processing element
  array/          6x6 PE grid + array controller FSM
  mem/            BSRAM scratchpad
  feeder/         weight/activation staging + result drain/writeback
  uart/           UART rx/tx + generic FIFO
  ctrl/           CRC-8, UART protocol parser/dispatcher
  top/            top-level integration, reset synchronizer
sim/            GHDL testbenches (+ a UART bus-functional-model package)
constraints/    Pin constraints (.cst) for nextpnr-himbaechel/apycula
examples/       minimal blinky bring-up smoke test
scripts/        build.sh / sim.sh / sim_all.sh / program.sh
python/         host driver + CLI (`fpga-systolic`)
docs/           architecture.md, protocol.md, memory_map.md, bringup.md
```

## Quick start

### Simulate everything

```bash
scripts/sim_all.sh          # or: make sim-all
scripts/sim.sh tb_top --wave   # single testbench + waveform dump
```

### Build the bitstream

```bash
scripts/build.sh          # synthesis -> place&route -> build/top.fs
```

### Host driver

```bash
cd python
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/pytest tests/ -v                      # host-only, no hardware needed

.venv/bin/fpga-systolic ping -p /dev/ttyUSB0
.venv/bin/fpga-systolic run -p /dev/ttyUSB0 --mode ws --random --verify
```

### Hardware (once you have a board -- see docs/bringup.md)

```bash
scripts/program.sh build/top.fs
```

## Documentation

- [`docs/architecture.md`](docs/architecture.md) -- dataflow design (WS/OS),
  toolchain findings, resource/capacity story
- [`docs/protocol.md`](docs/protocol.md) -- UART frame format, opcode table
- [`docs/memory_map.md`](docs/memory_map.md) -- scratchpad BSRAM layout
- [`docs/bringup.md`](docs/bringup.md) -- hardware bring-up checklist
