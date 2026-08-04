#!/usr/bin/env bash
# Runs the full testbench suite in dependency order (leaf modules first,
# full-chip last), exiting non-zero on the first failure. Usable as a
# pre-commit-style gate even without a CI system.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# name:stop-time
TESTBENCHES=(
  "tb_pe:1ms"
  "tb_systolic_array:1ms"
  "tb_scratchpad:1ms"
  "tb_core_integration:1ms"
  "tb_crc8:1ms"
  "tb_uart_loopback:1ms"
  "tb_sync_fifo:1ms"
  "tb_cmd_processor:1ms"
  "tb_top:2ms"
)

FAILED=()
for entry in "${TESTBENCHES[@]}"; do
  name="${entry%%:*}"
  stop_time="${entry##*:}"
  echo ""
  echo "############################################################"
  echo "# ${name}"
  echo "############################################################"
  if "${SCRIPT_DIR}/sim.sh" "${name}" "--stop-time=${stop_time}" 2>&1 | tee "/tmp/${name}.simlog" | grep -v "metavalue"; then
    if grep -q "FAILED\|simulation failed" "/tmp/${name}.simlog"; then
      FAILED+=("${name}")
    fi
  else
    FAILED+=("${name}")
  fi
done

echo ""
echo "############################################################"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "# ALL TESTBENCHES PASSED"
  echo "############################################################"
  exit 0
else
  echo "# FAILED: ${FAILED[*]}"
  echo "############################################################"
  exit 1
fi
