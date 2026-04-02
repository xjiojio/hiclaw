#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"
test_setup "22-task-protocol-state-machine"
minio_setup
TASK_ID="task-22-$(date +%s)"
CREATOR="${TEST_ADMIN_USER}"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action create --task-id ${TASK_ID} --title Test22 --type finite --created-by ${CREATOR}"
RET=$?
if [ $RET -ne 0 ]; then
  log_fail "manage-task-meta create failed"
  test_teardown "22-task-protocol-state-machine"
  test_summary
  exit 1
fi
exec_in_manager bash -lc "mc stat \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json\" >/dev/null 2>&1"
if [ $? -ne 0 ]; then
  log_fail "meta.json not found in MinIO"
  test_teardown "22-task-protocol-state-machine"
  test_summary
  exit 1
fi
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-assignee --task-id ${TASK_ID} --assigned-to alice"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${TASK_ID} --status in_progress"
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh --action set-status --task-id ${TASK_ID} --status completed --result-summary Done"
META=$(exec_in_manager bash -lc "mc cat \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json\" | jq -r '.status'")
if [ "${META}" = "completed" ]; then
  log_pass "state-machine completed transition ok"
else
  log_fail "unexpected status: ${META}"
fi
test_teardown "22-task-protocol-state-machine"
test_summary
