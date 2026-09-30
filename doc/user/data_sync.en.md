# App Data Synchronization

中文版本：[data_sync.zh.md](data_sync.zh.md)

Navigation: **Settings → App → Data Sync**. Enter your WebDAV directory URL, username, and password. Match the server directory's exact letter case. You can use **Test Connection** to verify directory accessibility.

App data includes settings, favorites, history, cookies, and comic source script files; it does not include local comic images. Comic archive backups and the online WebDAV comic library are configured separately.

## Sync Modes

| Mode | Trigger & Behavior |
|---|---|
| Manual | Transfers only when you tap Upload or Download on the Home sync card |
| Real-time | Automatically uploads when local data changes; checks for remote updates on app startup and resume (resume checks debounced by at least 10 minutes) |
| Scheduled | Periodically syncs at a configured interval: 5, 15, 30, 60, 180, or 360 minutes (default 30 minutes) |

Scheduled sync batches multiple local modifications within the interval into a single upload: if there are pending local edits, it uploads them; if there are no pending edits, it checks the remote version and downloads only when a newer snapshot is available. Edits made while an upload is in progress remain pending for the next interval; if an upload fails, the pending flag is retained and retried on the next scheduled run.

The timer runs as an in-app Timer only while the app process is running; it does not wake the operating system after closing, nor does it act as an OS-level background periodic service. The pending sync state (`webdavSyncPending`) and last attempt timestamp (`webdavSyncLastAttempt`) are persisted in the device's local state. Overdue syncs are executed when the app restarts or returns to the foreground; otherwise the app waits for the remainder of the interval. On mobile platforms, operating system background execution limits may affect exact timing.

The Home Upload and Download buttons can be triggered immediately in all three modes; manually triggering an operation resets the timer from completion time. An explicit download applies the remote snapshot following established import rules. If you have un-uploaded local edits, confirm which device's state to keep first; synchronization operates on complete snapshots rather than multi-master three-way conflict merging.

## Device-Local Boundaries and Credentials

To ensure security and multi-device autonomy, the following items are strictly **device-local** and are never exported into remote sync snapshots (`.venera`) or overwritten by remote downloads:

- **WebDAV Sync Credentials & Connection Info**: WebDAV URL, username, and password.
- **Current Device Sync Scheduling**: Selected sync mode (manual/real-time/scheduled) and scheduled interval.
- **Local Pending State & Retry Queues**: Local pending flags, last attempt timestamp, and local retry queues.
- **Local Storage Path**: Configured local comics storage path (`local_path`).
- **Bangumi Local Queues**: Pending Bangumi progress submissions and local background retry queues.

Remote sync snapshots only contain: `history.db`, `local_favorite.db`, `appdata.json` (filtered of device-local settings and paths), `cookie.db`, and installed comic source scripts (`comic_source/`).

> **WebDAV Comic Library Configuration Sync**:
> In "WebDAV Comic Library" settings, the "Sync Comic Library Config" option is disabled by default. Only when explicitly enabled on both devices will library connection endpoints and credentials be included in the snapshot. Credentials reside inside the remote snapshot; only enable this on trusted WebDAV servers.

## Saving Settings and Migration

When selecting real-time or scheduled mode, choose an initial upload or download and tap "Continue". New settings are committed only after the initial operation succeeds; failures safely roll back to previous endpoints, modes, intervals, and filter settings without leaving the client in a busy state. In manual mode, "Continue" saves settings immediately.

Changing the mode or interval reschedules the next sync immediately. Clearing the URL, username, and password disconnects synchronization. Legacy auto-sync maps to real-time mode when enabled and manual mode when disabled; upgrades will not switch to scheduled sync automatically.
