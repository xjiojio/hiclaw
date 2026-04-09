#!/bin/bash
set -euo pipefail
BASELINE_JSON="${1:-}"
CURRENT_JSON="${2:-}"
if [ -z "${BASELINE_JSON}" ] || [ -z "${CURRENT_JSON}" ]; then
  echo "usage: $0 <baseline-json-file> <current-json-file>"
  exit 1
fi
if [ ! -s "${BASELINE_JSON}" ] || [ ! -s "${CURRENT_JSON}" ]; then
  echo "input json file is empty: baseline=${BASELINE_JSON} current=${CURRENT_JSON}" >&2
  exit 1
fi
base_qps=$(jq -r '.qps' "${BASELINE_JSON}")
curr_qps=$(jq -r '.qps' "${CURRENT_JSON}")
base_ms=$(jq -r '.elapsed_ms' "${BASELINE_JSON}")
curr_ms=$(jq -r '.elapsed_ms' "${CURRENT_JSON}")
base_p99=$(jq -r '.p99_op_ms // 0' "${BASELINE_JSON}")
curr_p99=$(jq -r '.p99_op_ms // 0' "${CURRENT_JSON}")
if [ -z "${base_qps}" ] || [ -z "${curr_qps}" ] || [ -z "${base_ms}" ] || [ -z "${curr_ms}" ]; then
  echo "invalid benchmark json content" >&2
  exit 1
fi
qps_gain=$(awk -v b="${base_qps}" -v c="${curr_qps}" 'BEGIN { if (b==0) {print "0.00"} else {printf "%.2f", ((c-b)/b)*100} }')
latency_drop=$(awk -v b="${base_ms}" -v c="${curr_ms}" 'BEGIN { if (b==0) {print "0.00"} else {printf "%.2f", ((b-c)/b)*100} }')
p99_drop=$(awk -v b="${base_p99}" -v c="${curr_p99}" 'BEGIN { if (b==0) {print "0.00"} else {printf "%.2f", ((b-c)/b)*100} }')
echo "{"
echo "  \"baseline_qps\": ${base_qps},"
echo "  \"current_qps\": ${curr_qps},"
echo "  \"qps_gain_percent\": ${qps_gain},"
echo "  \"baseline_elapsed_ms\": ${base_ms},"
echo "  \"current_elapsed_ms\": ${curr_ms},"
echo "  \"latency_drop_percent\": ${latency_drop},"
echo "  \"baseline_p99_op_ms\": ${base_p99},"
echo "  \"current_p99_op_ms\": ${curr_p99},"
echo "  \"p99_drop_percent\": ${p99_drop}"
echo "}"
