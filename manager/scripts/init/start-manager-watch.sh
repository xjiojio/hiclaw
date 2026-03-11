#!/bin/bash
# start-manager-watch.sh - Start the manager-watch service
#
# This script is intended to be run by supervisord.

# Ensure data directory exists
mkdir -p /data/manager-watch

# Set default env vars if not present
export HICLAW_WATCH_PORT="${HICLAW_WATCH_PORT:-19090}"
export HICLAW_WATCH_USER="${HICLAW_WATCH_USER:-admin}"

# Fallback to admin password if watch password not set
if [ -z "${HICLAW_WATCH_PASSWORD}" ]; then
    export HICLAW_WATCH_PASSWORD="${HICLAW_ADMIN_PASSWORD}"
fi

# Log start
echo "[hiclaw-watch] Starting manager-watch on port ${HICLAW_WATCH_PORT}..."
echo "[hiclaw-watch] Data directory: /data/manager-watch"

# Run the python script
exec python3 /opt/hiclaw/manager/scripts/manager-watch/manager-watch.py
