#!/usr/bin/env bash
# Shared config for the Gowin-toolchain scripts (build.sh, program.sh).
# Locates the Gowin EDA install and its two CLI tools -- gw_sh (headless
# Tcl shell, used for synthesis/P&R/bitstream) and programmer_cli (SRAM/
# flash programming) -- and defines the device identity those tools
# need. See docs/bringup.md for how this toolchain choice came about:
# the project's original oss-cad-suite flow (yosys+GHDL ->
# nextpnr-himbaechel -> apycula) couldn't be gotten running end-to-end
# in this repo's Linux environment, so Gowin's own (free/Education-tier)
# EDA is the toolchain actually in use now, run headlessly with no GUI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Override with your own install path if it's not auto-detected, e.g.:
#   GOWIN_DIR="/c/Gowin/Gowin_V1.9.11.03_Education_x64" scripts/build.sh
if [ -z "${GOWIN_DIR:-}" ]; then
  # Prefer an already-versioned install under C:\Gowin (Windows) or
  # /opt or /usr/local (Linux/macOS Gowin installs), newest first.
  for candidate in \
    /c/Gowin/Gowin_V*_Education_x64 \
    /c/Gowin/Gowin_V* \
    /opt/gowin/Gowin_V*_Education \
    /opt/gowin/Gowin_V* \
    "${HOME}/gowin/Gowin_V*"; do
    for dir in $candidate; do
      if [ -x "${dir}/IDE/bin/gw_sh" ] || [ -x "${dir}/IDE/bin/gw_sh.exe" ]; then
        GOWIN_DIR="${dir}"
      fi
    done
  done
fi

if [ -z "${GOWIN_DIR:-}" ] || [ ! -d "${GOWIN_DIR}" ]; then
  echo "error: couldn't find a Gowin EDA install." >&2
  echo "  Set GOWIN_DIR to the install root, e.g.:" >&2
  echo "  GOWIN_DIR=\"/c/Gowin/Gowin_V1.9.11.03_Education_x64\" $0" >&2
  exit 1
fi

GW_SH="${GOWIN_DIR}/IDE/bin/gw_sh"
[ -x "${GW_SH}" ] || GW_SH="${GOWIN_DIR}/IDE/bin/gw_sh.exe"

PROGRAMMER_CLI="${GOWIN_DIR}/Programmer/bin/programmer_cli"
[ -x "${PROGRAMMER_CLI}" ] || PROGRAMMER_CLI="${GOWIN_DIR}/Programmer/bin/programmer_cli.exe"

# Device identity for programmer_cli (gw_sh gets this from gowin/build.tcl
# instead, since create_project needs -device_version too).
GOWIN_DEVICE="GW2AR-18C"      # --device value programmer_cli expects
GOWIN_DEVICE_ID="0x0000081B"  # JTAG IDCODE, used to sanity-check --scan output

# "USB Debugger A" -- the Tang Nano 20K's onboard FT2232H-based
# debugger/UART bridge. More than one FT2232H/JTAG device can show up
# in --scan-cables at once (its two channels enumerate separately) even
# with a single board attached -- verify by GOWIN_DEVICE_ID, don't just
# assume cable-index 0.
CABLE_INDEX=4

PROJECT_NAME="mosaic"
PROJECT_DIR="${REPO_ROOT}/gowin/proj"
BITSTREAM="${PROJECT_DIR}/${PROJECT_NAME}/impl/pnr/${PROJECT_NAME}.fs"
