#!/bin/bash
set -euo pipefail
STATE_FILE="${HOME}/state.json"
TASK_ROOT="/root/hiclaw-fs/shared/tasks"
PROTOCOL_MODE="${HICLAW_TASK_PROTOCOL_MODE:-compatible}"
if [ ! -f "${STATE_FILE}" ]; then
  echo '{"code":"OK","message":"no state file"}'
  exit 0
fi
if [ -f /opt/hiclaw/scripts/lib/hiclaw-env.sh ]; then
  . /opt/hiclaw/scripts/lib/hiclaw-env.sh
else
  . /opt/hiclaw/scripts/lib/oss-credentials.sh 2>/dev/null || true
  ensure_mc_credentials 2>/dev/null || true
fi
ensure_mc_credentials 2>/dev/null || true
completed=0
for task_id in $(jq -r '.active_tasks[] | select(.type=="finite") | .task_id' "${STATE_FILE}"); do
  task_dir="${TASK_ROOT}/${task_id}"
  mkdir -p "${task_dir}"
  mc cp "${HICLAW_STORAGE_PREFIX}/shared/tasks/${task_id}/meta.json" "${task_dir}/meta.json" >/dev/null 2>&1 || true
  mc cp "${HICLAW_STORAGE_PREFIX}/shared/tasks/${task_id}/result.md" "${task_dir}/result.md" >/dev/null 2>&1 || true
  if [ ! -f "${task_dir}/meta.json" ]; then
    continue
  fi
  status="$(jq -r '.status // ""' "${task_dir}/meta.json")"
  if [ "${status}" = "completed" ] || [ "${status}" = "cancelled" ]; then
    bash /opt/hiclaw/agent/skills/task-management/scripts/manage-state.sh --action complete --task-id "${task_id}" >/dev/null 2>&1 || true
    continue
  fi
  if [ -s "${task_dir}/result.md" ]; then
    ok=0
    case "${status}" in
      in_progress)
        if bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh \
          --action set-status --task-id "${task_id}" --status completed >/dev/null 2>&1; then
          ok=1
        fi
        ;;
      created|assigned|blocked)
        if [ "${PROTOCOL_MODE}" = "compatible" ] && \
           bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh \
            --action set-status --task-id "${task_id}" --status in_progress >/dev/null 2>&1 && \
           bash /opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh \
            --action set-status --task-id "${task_id}" --status completed >/dev/null 2>&1; then
          ok=1
        fi
        ;;
    esac
    if [ "${ok}" -eq 1 ]; then
      bash /opt/hiclaw/agent/skills/task-management/scripts/manage-state.sh --action complete --task-id "${task_id}" >/dev/null 2>&1 || true
      completed=$((completed + 1))
    fi
  fi
done
printf '{"code":"OK","message":"reconciled","mode":"%s","completed":%d}\n' "${PROTOCOL_MODE}" "${completed}"
