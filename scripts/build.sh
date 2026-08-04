#!/usr/bin/env bash
# Synthesis-only lint/resource-check via yosys+GHDL. synth_gowin's
# BSRAM/DSP inference is device-family-generic (not chipdb-dependent),
# so this step works and its resource report is meaningful even though
# this exact oss-cad-suite build cannot place&route or pack a bitstream
# for GW1NSR-18C (Tang Nano 20K) -- confirmed empirically, see
# docs/architecture.md. For the real bitstream, import the rtl/*.vhd
# sources + constraints/tangnano20k.cst into Gowin EDA (free,
# proprietary) targeting GW1NSR-LV18QN88PC6/I5 and run synthesis+P&R
# there -- see docs/bringup.md for the exact steps. The resulting
# bitstream (.fs) can then still be flashed with scripts/program.sh,
# since openFPGALoader itself is not chipdb-limited.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TOP_MODULE="${1:-top}"

echo "== synthesis (yosys + ghdl plugin) -- lint + resource estimate only =="
FILE_LIST=$(printf '%s ' "${RTL_FILES[@]}")
yosys -m ghdl -p "
  ghdl --std=08 ${FILE_LIST} -e ${TOP_MODULE};
  synth_gowin -top ${TOP_MODULE} -json ${BUILD_DIR}/${TOP_MODULE}.json
"

echo ""
echo "############################################################"
echo "Synthesis OK. Resource counts above are meaningful (BSRAM/DSP"
echo "inference doesn't depend on the exact device), but this build"
echo "cannot go further: nextpnr-himbaechel and gowin_pack in this"
echo "oss-cad-suite have no chipdb for GW1NSR-18C (Tang Nano 20K)."
echo ""
echo "Next step (outside this toolchain): import rtl/*.vhd and"
echo "constraints/tangnano20k.cst into Gowin EDA, target device"
echo "${DEVICE_FULL}, run Synthesize + Place & Route there. Then:"
echo "  scripts/program.sh <path-to-gowin-eda-output.fs>"
echo "See docs/bringup.md for the full walkthrough."
echo "############################################################"
