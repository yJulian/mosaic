#!/usr/bin/env bash
# Analyze+elaborate+run a single testbench.
#   scripts/sim.sh tb_pe
#   scripts/sim.sh tb_top --wave        # also dump a .ghw waveform
#   scripts/sim.sh tb_top --stop-time=5ms
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <testbench_name> [--wave] [--stop-time=<time>]" >&2
  exit 1
fi
TB_NAME="$1"; shift

WAVE=0
STOP_TIME="1ms"
for arg in "$@"; do
  case "$arg" in
    --wave) WAVE=1 ;;
    --stop-time=*) STOP_TIME="${arg#--stop-time=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

TB_FILE="${REPO_ROOT}/sim/${TB_NAME}.vhd"
if [ ! -f "${TB_FILE}" ]; then
  echo "no such testbench: ${TB_FILE}" >&2
  exit 1
fi

echo "== analyzing RTL + BFM package + ${TB_NAME} =="
ghdl -a --std=08 --workdir="${BUILD_DIR}" "${RTL_FILES[@]}" "${SIM_BFM_FILES[@]}" "${TB_FILE}"

echo "== elaborating ${TB_NAME} =="
ghdl -e --std=08 --workdir="${BUILD_DIR}" -o "${BUILD_DIR}/${TB_NAME}" "${TB_NAME}"

RUN_ARGS=(--stop-time="${STOP_TIME}")
if [ "${WAVE}" = "1" ]; then
  RUN_ARGS+=(--wave="${BUILD_DIR}/${TB_NAME}.ghw")
fi

echo "== running ${TB_NAME} (stop-time=${STOP_TIME}) =="
if [ -x "${BUILD_DIR}/${TB_NAME}" ]; then
  "${BUILD_DIR}/${TB_NAME}" "${RUN_ARGS[@]}"
else
  # mcode (JIT) backend: `-e` doesn't produce a standalone binary --
  # confirmed on this repo's Windows GHDL install -- so run via `-r`
  # instead, which works for both mcode and real (llvm/gcc) backends.
  ghdl -r --std=08 --workdir="${BUILD_DIR}" "${TB_NAME}" "${RUN_ARGS[@]}"
fi

if [ "${WAVE}" = "1" ]; then
  echo "waveform: ${BUILD_DIR}/${TB_NAME}.ghw  (open with: gtkwave ${BUILD_DIR}/${TB_NAME}.ghw)"
fi
