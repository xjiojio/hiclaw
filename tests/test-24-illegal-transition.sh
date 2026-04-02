#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
source "${SCRIPT_DIR}/lib/minio-client.sh"

test_setup "24-illegal-transition"
minio_setup

TASK_ID="task-24-$(date +%s)"
CREATOR="${TEST_ADMIN_USER}"

# Create meta
exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh \
  --action create --task-id ${TASK_ID} --title T24 --type finite --created-by ${CREATOR}"

# Try illegal transition: created -> completed
OUT=$(exec_in_manager bash -lc "bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh \
  --action set-status --task-id ${TASK_ID} --status completed" 2>/dev/null || true)

if echo "${OUT}" | grep -q 'E_INVALID_TRANSITION'; then
  log_pass "illegal transition rejected (created -> completed)"
else
  log_fail "illegal transition was not rejected: ${OUT}"
fi

test_teardown "24-illegal-transition"
test_summary
