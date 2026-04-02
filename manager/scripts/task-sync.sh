#!/bin/bash
set -euo pipefail
ACTION=""
TASK_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    pull|pull-full|push) ACTION="$1"; shift ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    *) echo '{"code":"E_ARGS","message":"invalid argument"}'; exit 1 ;;
  esac
done
if [ -z "${ACTION}" ] || [ -z "${TASK_ID}" ]; then
  echo '{"code":"E_ARGS","message":"missing action or task-id"}'
  exit 1
fi
if [ -f /opt/hiclaw/scripts/lib/hiclaw-env.sh ]; then
  . /opt/hiclaw/scripts/lib/hiclaw-env.sh
else
  . /opt/hiclaw/scripts/lib/oss-credentials.sh 2>/dev/null || true
  ensure_mc_credentials 2>/dev/null || true
  HICLAW_STORAGE_PREFIX="${HICLAW_STORAGE_PREFIX:-hiclaw/hiclaw-storage}"
fi
ensure_mc_credentials 2>/dev/null || true
HICLAW_ROOT="/root/hiclaw-fs"
LOCAL_DIR="${HICLAW_ROOT}/shared/tasks/${TASK_ID}"
REMOTE_DIR="${HICLAW_STORAGE_PREFIX}/shared/tasks/${TASK_ID}"
mkdir -p "${LOCAL_DIR}"
case "${ACTION}" in
  pull)
    mc cp "${REMOTE_DIR}/meta.json" "${LOCAL_DIR}/meta.json" >/dev/null 2>&1 || true
    mc cp "${REMOTE_DIR}/spec.md" "${LOCAL_DIR}/spec.md" >/dev/null 2>&1 || true
    mc mirror "${REMOTE_DIR}/base/" "${LOCAL_DIR}/base/" --overwrite >/dev/null 2>&1 || true
    echo '{"code":"OK","message":"pulled meta/spec/base"}'
    ;;
  pull-full)
    mc mirror "${REMOTE_DIR}/" "${LOCAL_DIR}/" --overwrite >/dev/null 2>&1 || true
    echo '{"code":"OK","message":"pulled full task dir"}'
    ;;
  push)
    if [ -f "${LOCAL_DIR}/plan.md" ]; then
      mc cp "${LOCAL_DIR}/plan.md" "${REMOTE_DIR}/plan.md" >/dev/null 2>&1 || true
    fi
    if [ -f "${LOCAL_DIR}/result.md" ]; then
      mc cp "${LOCAL_DIR}/result.md" "${REMOTE_DIR}/result.md" >/dev/null 2>&1 || true
    fi
    if [ -d "${LOCAL_DIR}/progress" ]; then
      mc mirror "${LOCAL_DIR}/progress/" "${REMOTE_DIR}/progress/" --overwrite >/dev/null 2>&1 || true
    fi
    echo '{"code":"OK","message":"pushed plan/result/progress"}'
    ;;
esac
