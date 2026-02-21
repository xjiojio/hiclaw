#!/bin/bash
# start-mc-mirror.sh - Initialize MinIO storage and start bidirectional file sync
#
# Manager's own workspace (~/manager-workspace/) is LOCAL ONLY and not synced to MinIO.
# MinIO only stores shared data and worker configs (~/hiclaw-fs/).

source /opt/hiclaw/scripts/lib/base.sh
waitForService "MinIO" "127.0.0.1" 9000

# Configure mc alias (local access, not through Higress)
mc alias set hiclaw http://127.0.0.1:9000 "${HICLAW_MINIO_USER:-${HICLAW_ADMIN_USER:-admin}}" "${HICLAW_MINIO_PASSWORD:-${HICLAW_ADMIN_PASSWORD:-admin}}"

# Create default bucket
mc mb hiclaw/hiclaw-storage --ignore-existing

# Initialize placeholder directories for shared data and worker artifacts
for dir in shared/knowledge shared/tasks workers; do
    echo "" | mc pipe "hiclaw/hiclaw-storage/${dir}/.gitkeep" 2>/dev/null || true
done

# Create local mirror directory (for shared + worker data only)
mkdir -p ~/hiclaw-fs

# Initial full sync to local (workers + shared)
mc mirror hiclaw/hiclaw-storage/ ~/hiclaw-fs/ --overwrite

# Signal that initialization is complete
touch ~/hiclaw-fs/.initialized

log "MinIO storage initialized and synced to ~/hiclaw-fs/"

# Start bidirectional sync (shared + worker data only — manager workspace excluded)
# Local -> Remote: real-time watch (filesystem notify)
mc mirror --watch ~/hiclaw-fs/ hiclaw/hiclaw-storage/ --overwrite &
LOCAL_TO_REMOTE_PID=$!

log "Local->Remote sync started (PID: ${LOCAL_TO_REMOTE_PID})"

# Remote -> Local: periodic pull every 5 minutes (aligned with heartbeat)
while true; do
    sleep 300
    mc mirror hiclaw/hiclaw-storage/ ~/hiclaw-fs/ --overwrite --newer-than "5m" 2>/dev/null || true
done
