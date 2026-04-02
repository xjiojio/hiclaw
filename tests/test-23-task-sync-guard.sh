#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/test-helpers.sh"
test_setup "23-task-sync-guard"
TASK_ID="task-23-$(date +%s)"
exec_in_manager bash -lc "mkdir -p /root/hiclaw-fs/shared/tasks/${TASK_ID}/base && printf '%s' '{\"task_id\":\"${TASK_ID}\",\"status\":\"assigned\"}' > /root/hiclaw-fs/shared/tasks/${TASK_ID}/meta.json && printf '%s' 'spec-v1' > /root/hiclaw-fs/shared/tasks/${TASK_ID}/spec.md && mc cp /root/hiclaw-fs/shared/tasks/${TASK_ID}/meta.json \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json\" && mc cp /root/hiclaw-fs/shared/tasks/${TASK_ID}/spec.md \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/spec.md\""
exec_in_manager bash -lc "printf '%s' '{\"task_id\":\"${TASK_ID}\",\"status\":\"tampered\"}' > /root/hiclaw-fs/shared/tasks/${TASK_ID}/meta.json && printf '%s' 'plan-v1' > /root/hiclaw-fs/shared/tasks/${TASK_ID}/plan.md && printf '%s' 'result-v1' > /root/hiclaw-fs/shared/tasks/${TASK_ID}/result.md"
exec_in_manager bash -lc "bash /opt/hiclaw/scripts/task-sync.sh push --task-id ${TASK_ID}"
REMOTE_META=$(exec_in_manager bash -lc "mc cat \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json\"")
REMOTE_PLAN=$(exec_in_manager bash -lc "mc cat \"\${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/plan.md\"")
if echo "${REMOTE_META}" | grep -q '"status":"assigned"' && [ "${REMOTE_PLAN}" = "plan-v1" ]; then
  log_pass "task-sync push protects meta/spec and uploads plan/result"
else
  log_fail "task-sync push guard failed"
fi
test_teardown "23-task-sync-guard"
test_summary
