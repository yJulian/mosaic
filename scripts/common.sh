#!/usr/bin/env bash
# Shared config sourced by every script in this directory: environment
# setup, device/family strings, and the RTL file list in the topological
# order GHDL/yosys need (dependencies before dependents).
set -euo pipefail

if [ -z "${OSS_CAD_SUITE_SOURCED:-}" ]; then
  source /opt/oss-cad-suite/environment
  export OSS_CAD_SUITE_SOURCED=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
mkdir -p "${BUILD_DIR}"

# Target: Tang Nano 20K (GW1NSR-LV18QN88PC6/I5). This oss-cad-suite
# build has NO chipdb for GW1NSR-18C in either nextpnr-himbaechel or
# apycula (confirmed empirically, see docs/architecture.md) -- so
# place&route and bitstream packing for this exact device are NOT
# possible with this open-source toolchain right now. synth_gowin
# itself is device-family-generic (BSRAM/DSP inference doesn't need the
# per-device chipdb), so scripts/build.sh still runs synthesis here for
# linting/resource estimates, then stops and points to Gowin EDA
# (proprietary, free) for the P&R+pack step -- see docs/bringup.md.
DEVICE_FULL="GW1NSR-LV18QN88PC6/I5"
BOARD="tangnano20k"       # accepted by openFPGALoader for programming a Gowin-EDA-built bitstream

RTL_FILES=(
  "${REPO_ROOT}/rtl/common/pkg_types.vhd"
  "${REPO_ROOT}/rtl/common/pkg_protocol.vhd"
  "${REPO_ROOT}/rtl/common/pkg_memmap.vhd"
  "${REPO_ROOT}/rtl/pe/pe.vhd"
  "${REPO_ROOT}/rtl/array/systolic_array.vhd"
  "${REPO_ROOT}/rtl/array/array_ctrl.vhd"
  "${REPO_ROOT}/rtl/mem/bram_sdp.vhd"
  "${REPO_ROOT}/rtl/mem/scratchpad.vhd"
  "${REPO_ROOT}/rtl/feeder/ws_weight_loader.vhd"
  "${REPO_ROOT}/rtl/feeder/skew_feeder.vhd"
  "${REPO_ROOT}/rtl/feeder/result_drainer.vhd"
  "${REPO_ROOT}/rtl/ctrl/crc8.vhd"
  "${REPO_ROOT}/rtl/uart/uart_rx.vhd"
  "${REPO_ROOT}/rtl/uart/uart_tx.vhd"
  "${REPO_ROOT}/rtl/uart/sync_fifo.vhd"
  "${REPO_ROOT}/rtl/ctrl/cmd_processor.vhd"
  "${REPO_ROOT}/rtl/top/clk_reset_gen.vhd"
  "${REPO_ROOT}/rtl/top/top.vhd"
)

SIM_BFM_FILES=(
  "${REPO_ROOT}/sim/uart_bfm_pkg.vhd"
)
