#!/usr/bin/env bash
# Build the bitstream via the Gowin toolchain (synthesis -> P&R ->
# bitstream in one headless `gw_sh` run of gowin/build.tcl -- no GUI,
# no Gowin project file to hand-maintain). See scripts/common_gowin.sh
# for how the Gowin install is located and docs/bringup.md for why this
# is the toolchain in use (the project's original oss-cad-suite flow
# never got working end-to-end in this repo's Linux environment).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_gowin.sh"

echo "== Gowin build (gw_sh) =="
"${GW_SH}" "${REPO_ROOT}/gowin/build.tcl"

echo ""
echo "############################################################"
echo "Build OK: ${BITSTREAM}"
echo "Program it with:"
echo "  scripts/program.sh"
echo "############################################################"
