#!/bin/bash
set -euo pipefail
MANAGER_CONTAINER="${1:-hiclaw-manager}"
ITERATIONS="${2:-200}"
PULL_POLICY="${3:-if-missing}"
TASK_ID_PREFIX="perf-task-$(date +%s)-${RANDOM}"
docker exec -e HICLAW_META_PULL_POLICY="${PULL_POLICY}" "${MANAGER_CONTAINER}" bash -s -- "${ITERATIONS}" "${TASK_ID_PREFIX}" "${MANAGER_CONTAINER}" "${PULL_POLICY}" <<'EOF'
set -euo pipefail
ITERATIONS="$1"
TASK_ID_PREFIX="$2"
CONTAINER_NAME="$3"
PULL_POLICY="$4"
SCRIPT="/opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh"
lat_file="$(mktemp)"
start_ts=$(date +%s%3N)
for i in $(seq 1 "${ITERATIONS}"); do
  tid="${TASK_ID_PREFIX}-${i}"
  t0=$(date +%s%3N)
  bash "${SCRIPT}" --action create --task-id "${tid}" --title perf --type finite --created-by admin >/dev/null
  t1=$(date +%s%3N)
  bash "${SCRIPT}" --action set-assignee --task-id "${tid}" --assigned-to alice >/dev/null
  t2=$(date +%s%3N)
  bash "${SCRIPT}" --action set-status --task-id "${tid}" --status in_progress >/dev/null
  t3=$(date +%s%3N)
  bash "${SCRIPT}" --action set-status --task-id "${tid}" --status completed >/dev/null
  t4=$(date +%s%3N)
  echo $((t1 - t0)) >> "${lat_file}"
  echo $((t2 - t1)) >> "${lat_file}"
  echo $((t3 - t2)) >> "${lat_file}"
  echo $((t4 - t3)) >> "${lat_file}"
done
end_ts=$(date +%s%3N)
elapsed_ms=$((end_ts - start_ts))
if [ "${elapsed_ms}" -le 0 ]; then
  elapsed_ms=1
fi
ops=$((ITERATIONS * 4))
qps=$(awk -v o="${ops}" -v e="${elapsed_ms}" 'BEGIN { printf "%.2f", (o*1000)/e }')
count="$(wc -l < "${lat_file}")"
if [ "${count}" -le 0 ]; then
  count=1
fi
idx=$(( (count * 99 + 99) / 100 ))
if [ "${idx}" -le 0 ]; then
  idx=1
fi
p99_op_ms="$(sort -n "${lat_file}" | sed -n "${idx}p")"
if [ -z "${p99_op_ms}" ]; then
  p99_op_ms=0
fi
avg_op_ms=$(awk -v s="${elapsed_ms}" -v c="${ops}" 'BEGIN { if (c==0) {print "0.00"} else {printf "%.2f", s/c} }')
rm -f "${lat_file}"
echo "{"
echo "  \"container\": \"${CONTAINER_NAME}\","
echo "  \"iterations\": ${ITERATIONS},"
echo "  \"ops\": ${ops},"
echo "  \"elapsed_ms\": ${elapsed_ms},"
echo "  \"qps\": ${qps},"
echo "  \"avg_op_ms\": ${avg_op_ms},"
echo "  \"p99_op_ms\": ${p99_op_ms},"
echo "  \"pull_policy\": \"${PULL_POLICY}\""
echo "}"
EOF
rc=$?
if [ "${rc}" -ne 0 ]; then
  echo "benchmark failed inside container: container=${MANAGER_CONTAINER} pull_policy=${PULL_POLICY}" >&2
  exit "${rc}"
fi
