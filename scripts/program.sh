#!/usr/bin/env bash
# Program the Tang Nano 20K via openFPGALoader. openFPGALoader itself
# isn't chipdb-limited the way nextpnr/gowin_pack are, so it can flash a
# bitstream (.fs) built by Gowin EDA just fine -- see docs/bringup.md.
#   scripts/program.sh <path-to.fs>            # load to SRAM (volatile, default)
#   scripts/program.sh <path-to.fs> --flash    # write to flash (persistent)
#   scripts/program.sh                         # defaults to build/top.fs
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BITSTREAM="${BUILD_DIR}/top.fs"
FLASH_MODE=0

for arg in "$@"; do
  case "$arg" in
    --flash) FLASH_MODE=1 ;;
    *) BITSTREAM="$arg" ;;
  esac
done

if [ ! -f "${BITSTREAM}" ]; then
  echo "no bitstream at ${BITSTREAM} -- build it in Gowin EDA first (see docs/bringup.md)" >&2
  echo "or pass the path explicitly: scripts/program.sh /path/to/project.fs" >&2
  exit 1
fi

if [ "${FLASH_MODE}" = "1" ]; then
  echo "== writing to flash (persistent) =="
  openFPGALoader -b "${BOARD}" -f "${BITSTREAM}"
else
  echo "== loading to SRAM (volatile) =="
  openFPGALoader -b "${BOARD}" "${BITSTREAM}"
fi
