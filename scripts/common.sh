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

# Target: Tang Nano 20K (GW2AR-LV18QN88C8/I7, device family GW2A-18C).
# Earlier revisions of this file targeted GW1NSR-LV18QN88PC6/I5, which
# was simply the wrong chip for this board (confirmed against Sipeed's
# own official example repo, github.com/sipeed/TangNano-20K-example,
# whose .cst headers say "Part Number: GW2AR-LV18QN88C8/I7"). That
# mistake was also why this project briefly believed Gowin's
# proprietary EDA was required: nextpnr-himbaechel/apycula genuinely
# have no chipdb for GW1NSR-18C, but this oss-cad-suite DOES ship a
# chipdb for GW2A-18C (which covers the GW2AR-18C variant's packages
# too) -- confirmed empirically by running P&R end-to-end. So the full
# open-source flow (yosys+GHDL -> nextpnr-himbaechel -> apycula
# gowin_pack -> openFPGALoader) works for this device; no Gowin EDA
# needed. See docs/bringup.md.
DEVICE_FULL="GW2AR-LV18QN88C8/I7"
DEVICE_FAMILY="GW2A-18C"  # -o family=... value nextpnr-himbaechel needs for GW2AR parts
BOARD="tangnano20k"       # accepted by openFPGALoader
CST_FILE="${REPO_ROOT}/constraints/tangnano20k.cst"

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
