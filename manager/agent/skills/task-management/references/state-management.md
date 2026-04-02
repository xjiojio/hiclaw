# State Management (state.json)

Path: `~/state.json`

Runtime index for active tasks. `meta.json` is the business source of truth for task status, while `state.json` is an operational cache used by heartbeat and scheduling.

**Always use `manage-state.sh` to modify** — never edit manually. The script handles initialization, deduplication, and atomic writes.

For status transitions in `meta.json`, use:

```bash
META_SCRIPT=/opt/hiclaw/agent/skills/task-management/scripts/manage-task-meta.sh
```

| When | Command |
|------|---------|
| Create meta | `bash $META_SCRIPT --action create --task-id T --title TITLE --type finite|infinite --created-by USER` |
| Assign worker | `bash $META_SCRIPT --action set-assignee --task-id T --assigned-to W` |
| Update status | `bash $META_SCRIPT --action set-status --task-id T --status created|assigned|in_progress|completed|blocked|cancelled` |
| Read meta | `bash $META_SCRIPT --action get --task-id T` |

## Script reference

```bash
STATE_SCRIPT=/opt/hiclaw/agent/skills/task-management/scripts/manage-state.sh
```

| When | Command |
|------|---------|
| Ensure file exists | `bash $STATE_SCRIPT --action init` |
| Assign finite task | `bash $STATE_SCRIPT --action add-finite --task-id T --title TITLE --assigned-to W --room-id R [--project-room-id P]` |
| Create infinite task | `bash $STATE_SCRIPT --action add-infinite --task-id T --title TITLE --assigned-to W --room-id R --schedule CRON --timezone TZ --next-scheduled-at ISO` |
| Finite task completed | `bash $STATE_SCRIPT --action complete --task-id T` |
| Infinite task executed | `bash $STATE_SCRIPT --action executed --task-id T --next-scheduled-at ISO` |
| Cache admin DM room | `bash $STATE_SCRIPT --action set-admin-dm --room-id R` |
| View active tasks | `bash $STATE_SCRIPT --action list` |

`admin_dm_room_id`: cached room ID for Manager-Admin DM. Set once via `set-admin-dm`, used by heartbeat to report to admin.

## Notification channel resolution

```bash
bash /opt/hiclaw/agent/skills/task-management/scripts/resolve-notify-channel.sh
```

Output: `{"channel": "dingtalk|matrix|none", "target": "...", "via": "primary-channel|admin-dm|none"}`

Priority: primary-channel.json (if confirmed, non-matrix) → state.json admin_dm_room_id → none.
