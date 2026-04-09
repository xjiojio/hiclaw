#!/bin/bash
set -euo pipefail
ACTION=""
TASK_ID=""
STATUS=""
TITLE=""
TYPE=""
ASSIGNED_TO=""
CREATED_BY=""
RESULT_SUMMARY=""
TASK_ROOT="/root/hiclaw-fs/shared/tasks"
PULL_POLICY="${HICLAW_META_PULL_POLICY:-if-missing}"
json() {
  local code="$1"
  local message="$2"
  printf '{"code":"%s","message":"%s"}\n' "$code" "$message"
}
now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="${2:-}"; shift 2 ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --status) STATUS="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --type) TYPE="${2:-}"; shift 2 ;;
    --assigned-to) ASSIGNED_TO="${2:-}"; shift 2 ;;
    --created-by) CREATED_BY="${2:-}"; shift 2 ;;
    --result-summary) RESULT_SUMMARY="${2:-}"; shift 2 ;;
    *) json "E_ARGS" "invalid argument: $1"; exit 1 ;;
  esac
done
if [ -z "$ACTION" ] || [ -z "$TASK_ID" ]; then
  json "E_ARGS" "missing --action or --task-id"
  exit 1
fi
TASK_DIR="${TASK_ROOT}/${TASK_ID}"
META_FILE="${TASK_DIR}/meta.json"
if [ -f /opt/hiclaw/scripts/lib/hiclaw-env.sh ]; then
  . /opt/hiclaw/scripts/lib/hiclaw-env.sh
else
  . /opt/hiclaw/scripts/lib/oss-credentials.sh 2>/dev/null || true
  ensure_mc_credentials 2>/dev/null || true
  HICLAW_STORAGE_PREFIX="${HICLAW_STORAGE_PREFIX:-hiclaw/hiclaw-storage}"
fi
ensure_mc_credentials 2>/dev/null || true
pull_meta() {
  mkdir -p "${TASK_DIR}"
  if [ "${PULL_POLICY}" = "if-missing" ] && [ -f "${META_FILE}" ]; then
    return 0
  fi
  mc cp "${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json" "${META_FILE}" >/dev/null 2>&1 || true
}
push_meta() {
  mc cp "${META_FILE}" "${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}/meta.json" >/dev/null 2>&1
}
validate_status() {
  case "$1" in
    created|assigned|in_progress|completed|blocked|cancelled|active) return 0 ;;
    *) return 1 ;;
  esac
}
can_transition() {
  local from="$1"
  local to="$2"
  if [ "$from" = "$to" ]; then return 0; fi
  case "${from}:${to}" in
    created:assigned|assigned:in_progress|assigned:cancelled|in_progress:completed|in_progress:blocked|in_progress:cancelled|blocked:in_progress|blocked:cancelled) return 0 ;;
    *) return 1 ;;
  esac
}
action_create() {
  if [ -z "$TITLE" ] || [ -z "$TYPE" ] || [ -z "$CREATED_BY" ]; then
    json "E_ARGS" "create requires --title --type --created-by"
    exit 1
  fi
  mkdir -p "${TASK_DIR}"
  if [ -f "${META_FILE}" ]; then
    json "E_ALREADY_EXISTS" "meta already exists"
    exit 1
  fi
  cat > "${META_FILE}" <<EOF
{
  "task_id": "${TASK_ID}",
  "title": "${TITLE}",
  "type": "${TYPE}",
  "status": "created",
  "created_at": "$(now_utc)",
  "created_by": "${CREATED_BY}",
  "assigned_to": null,
  "assigned_at": null,
  "completed_at": null,
  "result_summary": null
}
EOF
  push_meta
  json "OK" "meta created"
}
action_set_status() {
  if [ -z "$STATUS" ]; then
    json "E_ARGS" "set-status requires --status"
    exit 1
  fi
  if ! validate_status "$STATUS"; then
    json "E_INVALID_STATUS" "invalid status"
    exit 1
  fi
  pull_meta
  if [ ! -f "${META_FILE}" ]; then
    json "E_TASK_NOT_FOUND" "meta not found"
    exit 1
  fi
  local current
  current="$(jq -r '.status // ""' "${META_FILE}")"
  if ! can_transition "$current" "$STATUS"; then
    json "E_INVALID_TRANSITION" "${current}->${STATUS} not allowed"
    exit 1
  fi
  local tmp
  tmp="$(mktemp)"
  jq --arg s "$STATUS" --arg ts "$(now_utc)" --arg rs "${RESULT_SUMMARY}" '
    .status = $s
    | .updated_at = $ts
    | if $s == "completed" then .completed_at = $ts else . end
    | if ($rs != "") then .result_summary = $rs else . end
  ' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
  push_meta
  json "OK" "status updated to ${STATUS}"
}
action_set_assignee() {
  if [ -z "$ASSIGNED_TO" ]; then
    json "E_ARGS" "set-assignee requires --assigned-to"
    exit 1
  fi
  pull_meta
  if [ ! -f "${META_FILE}" ]; then
    json "E_TASK_NOT_FOUND" "meta not found"
    exit 1
  fi
  local tmp
  tmp="$(mktemp)"
  jq --arg w "$ASSIGNED_TO" --arg ts "$(now_utc)" '
    .assigned_to = $w
    | .assigned_at = $ts
    | if .status == "created" then .status = "assigned" else . end
    | .updated_at = $ts
  ' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
  push_meta
  json "OK" "assignee updated"
}
action_get() {
  pull_meta
  if [ ! -f "${META_FILE}" ]; then
    json "E_TASK_NOT_FOUND" "meta not found"
    exit 1
  fi
  cat "${META_FILE}"
}
case "$ACTION" in
  create) action_create ;;
  set-status) action_set_status ;;
  set-assignee) action_set_assignee ;;
  get) action_get ;;
  *) json "E_ARGS" "unsupported action"; exit 1 ;;
esac
