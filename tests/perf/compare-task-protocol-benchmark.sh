#!/bin/bash
set -euo pipefail
BASELINE_JSON="${1:-}"
CURRENT_JSON="${2:-}"
if [ -z "${BASELINE_JSON}" ] || [ -z "${CURRENT_JSON}" ]; then
  echo "usage: $0 <baseline-json-file> <current-json-file>"
  exit 1
fi
base_qps=$(jq -r '.qps' "${BASELINE_JSON}")
curr_qps=$(jq -r '.qps' "${CURRENT_JSON}")
base_ms=$(jq -r '.elapsed_ms' "${BASELINE_JSON}")
curr_ms=$(jq -r '.elapsed_ms' "${CURRENT_JSON}")
qps_gain=$(awk -v b="${base_qps}" -v c="${curr_qps}" 'BEGIN { if (b==0) {print "0.00"} else {printf "%.2f", ((c-b)/b)*100} }')
latency_drop=$(awk -v b="${base_ms}" -v c="${curr_ms}" 'BEGIN { if (b==0) {print "0.00"} else {printf "%.2f", ((b-c)/b)*100} }')
echo "{"
echo "  \"baseline_qps\": ${base_qps},"
echo "  \"current_qps\": ${curr_qps},"
echo "  \"qps_gain_percent\": ${qps_gain},"
echo "  \"baseline_elapsed_ms\": ${base_ms},"
echo "  \"current_elapsed_ms\": ${curr_ms},"
echo "  \"latency_drop_percent\": ${latency_drop}"
echo "}"
