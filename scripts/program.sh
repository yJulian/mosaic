#!/usr/bin/env bash
# Program the Tang Nano 20K via the Gowin toolchain's programmer_cli,
# using a bitstream built by scripts/build.sh -- see docs/bringup.md.
#   scripts/program.sh                         # SRAM, volatile (default)
#   scripts/program.sh /path/to/other.fs       # SRAM, explicit bitstream
#   scripts/program.sh --flash                 # embFlash, persistent
#
# SRAM is the right default for anything short of an intentional
# permanent deployment: it survives only until power-cycle, so a bad
# bitstream can never brick the board's boot image, and iterating is a
# few seconds per cycle instead of a flash erase/program/verify cycle.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_gowin.sh"

BITSTREAM_ARG="${BITSTREAM}"
FLASH_MODE=0

for arg in "$@"; do
  case "$arg" in
    --flash) FLASH_MODE=1 ;;
    *) BITSTREAM_ARG="$arg" ;;
  esac
done

if [ ! -f "${BITSTREAM_ARG}" ]; then
  echo "no bitstream at ${BITSTREAM_ARG} -- run scripts/build.sh first (see docs/bringup.md)" >&2
  echo "or pass the path explicitly: scripts/program.sh /path/to/project.fs" >&2
  exit 1
fi

echo "== scanning for a cable/device =="
"${PROGRAMMER_CLI}" --cable-index "${CABLE_INDEX}" --scan

if [ "${FLASH_MODE}" = "1" ]; then
  echo "== writing to flash (persistent) =="
  "${PROGRAMMER_CLI}" --cable-index "${CABLE_INDEX}" --device "${GOWIN_DEVICE}" \
    --operation_index 6 --fsFile "${BITSTREAM_ARG}"
else
  echo "== loading to SRAM (volatile) =="
  "${PROGRAMMER_CLI}" --cable-index "${CABLE_INDEX}" --device "${GOWIN_DEVICE}" \
    --operation_index 2 --fsFile "${BITSTREAM_ARG}"
fi
