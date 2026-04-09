#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
test_setup "26-reconcile-task-state"
minio_setup
TASK_ID="task-26-$(date +%s)"
CREATOR="${TEST_ADMIN_USER}"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action create --task-id ${TASK_ID} --title T26 --type finite --created-by ${CREATOR}"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-assignee --task-id ${TASK_ID} --assigned-to alice"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-state.sh --action add-finite --task-id ${TASK_ID} --title T26 --assigned-to alice --room-id room-test"
exec_in_manager bash -lc "printf '%s' 'result-ready' > /root/hiclaw-fs/shared/tasks/${TASK_ID}/result.md && . /opt/hiclaw/scripts/lib/hiclaw-env.sh && mc cp /root/hiclaw-fs/shared/tasks/${TASK_ID}/result.md \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/result.md\""
OUT=$(exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/reconcile-task-state.sh")
STATUS=$(exec_in_manager bash -lc ". /opt/hiclaw/scripts/lib/hiclaw-env.sh; mc cat \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json\" | jq -r '.status'")
LEFT=$(exec_in_manager bash -lc "jq -r --arg id \"${TASK_ID}\" '[.active_tasks[] | select(.task_id == \$id)] | length' ~/state.json")
if echo "${OUT}" | grep -q '"code":"OK"' && [ "${STATUS}" = "completed" ] && [ "${LEFT}" = "0" ]; then
  log_pass "reconcile completed meta and cleaned state index"
else
  log_fail "reconcile failed: out=${OUT} status=${STATUS} left=${LEFT}"
fi
test_teardown "26-reconcile-task-state"
test_summary
