#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
test_setup "25-blocked-cancelled"
minio_setup
TASK_ID="task-25-$(date +%s)"
CREATOR="${TEST_ADMIN_USER}"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action create --task-id ${TASK_ID} --title T25 --type finite --created-by ${CREATOR}"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-assignee --task-id ${TASK_ID} --assigned-to alice"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${TASK_ID} --status in_progress"
OUT1=$(exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${TASK_ID} --status blocked")
OUT2=$(exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${TASK_ID} --status cancelled")
STATUS=$(exec_in_manager bash -lc ". /opt/hiclaw/scripts/lib/hiclaw-env.sh; mc cat \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json\" | jq -r '.status'")
if echo "${OUT1}" | grep -q '"code":"OK"' && echo "${OUT2}" | grep -q '"code":"OK"' && [ "${STATUS}" = "cancelled" ]; then
  log_pass "blocked and cancelled transitions ok"
else
  log_fail "blocked/cancelled flow failed: out1=${OUT1} out2=${OUT2} status=${STATUS}"
fi
test_teardown "25-blocked-cancelled"
test_summary
