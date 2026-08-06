#!/usr/bin/env bash
# Full open-source build: synthesis (yosys+GHDL) -> place&route
# (nextpnr-himbaechel) -> bitstream packing (apycula gowin_pack). No
# Gowin EDA needed -- this oss-cad-suite build ships a chipdb for
# GW2A-18C, which covers the Tang Nano 20K's GW2AR-LV18QN88C8/I7 (see
# scripts/common.sh for how that was confirmed). Produces
# build/<top>.fs, ready for scripts/program.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TOP_MODULE="${1:-top}"

echo "== synthesis (yosys + ghdl plugin) =="
FILE_LIST=$(printf '%s ' "${RTL_FILES[@]}")
yosys -m ghdl -p "
  ghdl --std=08 ${FILE_LIST} -e ${TOP_MODULE};
  synth_gowin -top ${TOP_MODULE} -json ${BUILD_DIR}/${TOP_MODULE}.json
"

echo ""
echo "== place & route (nextpnr-himbaechel) =="
nextpnr-himbaechel \
  --device "${DEVICE_FULL}" \
  -o family="${DEVICE_FAMILY}" \
  -o cst="${CST_FILE}" \
  --json "${BUILD_DIR}/${TOP_MODULE}.json" \
  --write "${BUILD_DIR}/${TOP_MODULE}_pnr.json"

echo ""
echo "== bitstream packing (apycula gowin_pack) =="
gowin_pack \
  -d "${DEVICE_FAMILY}" \
  -o "${BUILD_DIR}/${TOP_MODULE}.fs" \
  "${BUILD_DIR}/${TOP_MODULE}_pnr.json"

echo ""
echo "############################################################"
echo "Build OK: ${BUILD_DIR}/${TOP_MODULE}.fs"
echo "Program it with:"
echo "  scripts/program.sh ${BUILD_DIR}/${TOP_MODULE}.fs"
echo "############################################################"
