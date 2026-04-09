#!/bin/bash
set -euo pipefail
MANAGER_CONTAINER="${1:-hiclaw-manager}"
ITERATIONS="${2:-200}"
TASK_ID_PREFIX="perf-task-$(date +%s)"
run_in_manager() {
  docker exec "${MANAGER_CONTAINER}" bash -lc "$1"
}
start_ts=$(date +%s%3N)
for i in $(seq 1 "${ITERATIONS}"); do
  tid="${TASK_ID_PREFIX}-${i}"
  run_in_manager "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action create --task-id ${tid} --title perf --type finite --created-by admin >/dev/null"
  run_in_manager "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-assignee --task-id ${tid} --assigned-to alice >/dev/null"
  run_in_manager "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${tid} --status in_progress >/dev/null"
  run_in_manager "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${tid} --status completed >/dev/null"
done
end_ts=$(date +%s%3N)
elapsed_ms=$((end_ts - start_ts))
if [ "${elapsed_ms}" -le 0 ]; then
  elapsed_ms=1
fi
ops=$((ITERATIONS * 4))
qps=$(awk -v o="${ops}" -v e="${elapsed_ms}" 'BEGIN { printf "%.2f", (o*1000)/e }')
echo "{"
echo "  \"container\": \"${MANAGER_CONTAINER}\","
echo "  \"iterations\": ${ITERATIONS},"
echo "  \"ops\": ${ops},"
echo "  \"elapsed_ms\": ${elapsed_ms},"
echo "  \"qps\": ${qps}"
echo "}"
