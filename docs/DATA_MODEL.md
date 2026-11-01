# teleBackup: data model

One Room (SQLite) database on the phone, owned by the Kotlin core: `telebackup.db` in the app's no-backup files folder. Flutter never opens it; it asks the core through the bridge (`docs/BRIDGE.md`). Secrets are **not** in this database (see "Secrets" at the end).

Times are epoch milliseconds (UTC) in `Long`. Sizes are bytes in `Long`. Enums are stored as their name (`TEXT`), never as numbers, so adding a value never breaks old rows.

## Tables

### `rules`
| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK autoincrement | |
| `name` | TEXT | 1-40 chars. Unique among rules not deleted (partial unique index). |
| `folderPath` | TEXT | Relative to shared storage root, with trailing slash, e.g. `DCIM/Camera/`. Matches MediaStore `RELATIVE_PATH`. |
| `includeSubfolders` | INTEGER (bool) | Default false. |
| `mediaTypes` | TEXT enum `MediaTypes` | `PHOTOS`, `VIDEOS`, `BOTH`. |
| `topicId` | INTEGER, nullable | Telegram `message_thread_id` (Bot API value). Null = General topic. FK to `topics.threadId`. |
| `uploadAs` | TEXT enum `UploadAs` | `MEDIA`, `ORIGINAL`. |
| `mode` | TEXT enum `RuleMode` | `UPLOAD_ONLY` (default), `UPLOAD_AND_DELETE`. |
| `retentionDays` | INTEGER | 1-365. Default from `rules.defaultRetentionDays`. |
| `startMode` | TEXT enum `StartMode` | `TODAY`, `SINCE_DATE`, `EVERYTHING`. |
| `startDate` | INTEGER, nullable | For `TODAY` = the moment the rule was saved; for `SINCE_DATE` = start of that day (local); null for `EVERYTHING`. |
| `enabled` | INTEGER (bool) | Default true. |
| `dryRun` | INTEGER (bool) | True on create. Turned false when the first delete review is approved. Can be set true again. |
| `deleteWarningAcceptedAt` | INTEGER, nullable | When D-DELETE-ON was accepted. Required (not null) for `UPLOAD_AND_DELETE`. |
| `deletedAt` | INTEGER, nullable | Soft delete (see "Deleting a rule"). |
| `createdAt`, `updatedAt` | INTEGER | |

Invariant (checked in `RuleValidator` and by a test): `mode == UPLOAD_AND_DELETE` implies `deleteWarningAcceptedAt != null`.

### `topics`
Topics teleBackup knows about. A bot cannot list a group's topics, so this table is the list the topic picker shows.
| Column | Type | Notes |
|---|---|---|
| `threadId` | INTEGER PK | Bot API `message_thread_id`. |
| `chatId` | INTEGER | The group it belongs to. Rows from an old group stay but are hidden. |
| `name` | TEXT | |
| `iconColor` | INTEGER, nullable | As returned by `createForumTopic`. |
| `source` | TEXT enum | `CREATED_BY_APP`, `FOUND_BY_ACCOUNT`. |
| `missing` | INTEGER (bool) | Set when Telegram says the thread is not found. |
| `createdAt` | INTEGER | |

### `files`
One row per (rule, file version). The heart of the app.
| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK autoincrement | |
| `ruleId` | INTEGER FK -> rules.id | No cascade: rules are soft-deleted (see "Deleting a rule"). |
| `mediaStoreId` | INTEGER, nullable | `_ID` from MediaStore; null when found by folder listing. |
| `path` | TEXT | Absolute path, e.g. `/storage/emulated/0/DCIM/Camera/IMG_1.jpg`. |
| `displayName` | TEXT | File name. |
| `mimeType` | TEXT | |
| `kind` | TEXT enum `FileKind` | `PHOTO`, `VIDEO`. |
| `sizeBytes` | INTEGER | At scan time. |
| `modifiedAt` | INTEGER | File last-modified at scan time. |
| `takenAt` | INTEGER | `DATE_TAKEN`, else date from the file name (`IMG-20261101-WA0001`), else `modifiedAt`. Sort key for "newest first". |
| `width`, `height` | INTEGER, nullable | From MediaStore, else read on hash. |
| `durationMs` | INTEGER, nullable | Videos. |
| `sha256` | TEXT, nullable | Full hex. Computed just before upload (not at scan, too slow for backlog). |
| `state` | TEXT enum `FileState` | See state machine. |
| `route` | TEXT enum `Route`, nullable | `BOT`, `ACCOUNT`. Decided at queue time, re-decided if settings change. |
| `sendAs` | TEXT enum `SendAs`, nullable | `PHOTO`, `VIDEO`, `DOCUMENT`. What was actually sent (a 12 MB photo with `MEDIA` goes as `DOCUMENT`). |
| `attempts` | INTEGER | Failed attempts that count (network drops do not count). |
| `nextAttemptAt` | INTEGER, nullable | When a `FAILED` file may be tried again. |
| `lastError` | TEXT, nullable | Short code + plain message, no secrets (e.g. `TG_400_BAD_REQUEST: wrong file type`). |
| `tgChatId` | INTEGER, nullable | Where it went. |
| `tgThreadId` | INTEGER, nullable | |
| `tgMessageId` | INTEGER, nullable | Bot API message id (for account uploads, converted to Bot API form). |
| `tgFileUniqueId` | TEXT, nullable | |
| `tgSize`, `tgWidth`, `tgHeight`, `tgDurationMs` | INTEGER, nullable | What Telegram reported back. |
| `queuedAt` | INTEGER | |
| `uploadedAt` | INTEGER, nullable | Send returned a message. |
| `verifiedAt` | INTEGER, nullable | Reply checks passed. |
| `deleteAfter` | INTEGER, nullable | `verifiedAt + retentionDays` (set when verified, recomputed if the rule's retention changes). Null for upload-only rules. |
| `deletedAt` | INTEGER, nullable | |
| `freedBytes` | INTEGER | 0 until deleted. |
| `reviewId` | INTEGER, nullable | FK -> reviews.id when it is part of a waiting review. |
| `createdAt`, `updatedAt` | INTEGER | |

Indexes:
- unique `(ruleId, path, sizeBytes, modifiedAt)`: the identity of a file version.
- `(state, nextAttemptAt)`: the queue query.
- `(ruleId, state)`: rule counts.
- `(state, deleteAfter)`: the cleaner query.
- `(takenAt DESC)`: ordering.
- `(sha256)`: duplicate check.

### `reviews`
A delete review (dry-run) waiting for the person.
| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `ruleId` | INTEGER FK | One open review per rule at most. |
| `createdAt` | INTEGER | |
| `fileCount`, `totalBytes` | INTEGER | |
| `status` | TEXT enum | `WAITING`, `APPROVED`, `DISMISSED`, `STALE` (a file in it changed, so it is rebuilt). |
| `decidedAt` | INTEGER, nullable | |

### `events`
For History and Diagnostics. Pruned to 90 days by the daily job.
| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `at` | INTEGER | |
| `kind` | TEXT enum `EventKind` | See below. |
| `ruleId` | INTEGER, nullable | |
| `fileId` | INTEGER, nullable | |
| `bytes` | INTEGER, nullable | |
| `message` | TEXT | Plain words, already redacted. |

`EventKind`: `SCAN_DONE`, `QUEUED_BATCH`, `UPLOADED`, `VERIFIED`, `VERIFY_FAILED`, `FAILED`, `SKIPPED`, `RETRIED`, `DELETED`, `DELETE_DENIED`, `CHANGED`, `GONE`, `REVIEW_CREATED`, `REVIEW_APPROVED`, `PAUSED`, `RESUMED`, `DELAYED`, `RUN_STOPPED` (with reason: network lost, time limit, paused, error), `LOGIN_EXPIRED`, `PERMISSION_LOST`, `PERMISSION_BACK`, `TOPIC_MISSING`, `BOT_PROBLEM`, `KILL_SWITCH`, `SETTINGS_CHANGED`.

### `settings`
Key/value (`key TEXT PK`, `value TEXT`). Typed access through `SettingsRepository`; unknown keys are ignored. Defaults live in code, not in the table.
| Key | Type | Default | Meaning |
|---|---|---|---|
| `app.setupDoneAt` | Long? | null | Setup finished. |
| `app.setupStep` | String | `O1` | Where setup resumes. |
| `network.allowMobileData` | Bool | false | |
| `network.mobileOnceUntilEmpty` | Bool | false | "Use mobile data once". Cleared when the queue empties. |
| `control.state` | `RUNNING`/`PAUSED`/`DELAYED` | `RUNNING` | |
| `control.delayedUntil` | Long? | null | |
| `control.delayOptionsMinutes` | CSV ints | `120,300` | 1-4 values, each 15-1440. |
| `rules.defaultRetentionDays` | Int | 7 | |
| `upload.botPacePerMinute` | Int | 15 | Max bot messages per minute into the group. |
| `upload.accountMinGapSeconds` | Int | 10 | Gap between account uploads. |
| `upload.maxAttempts` | Int | 5 | Then `SKIPPED`. |
| `upload.botMaxBytes` | Long | 52428800 (50 MB) | Strictly less than this goes by bot. |
| `upload.botPhotoMaxBytes` | Long | 10485760 (10 MB) | Photo as media limit for bots. |
| `telegram.botId` | Long? | | From `getMe`. |
| `telegram.botUsername` | String? | | |
| `telegram.chatId` | Long? | | The group. |
| `telegram.chatTitle` | String? | | |
| `account.state` | `NONE`/`READY`/`EXPIRED` | `NONE` | Mirror of TDLib state for quick reads. |
| `account.displayName` | String? | | Shown as "Logged in as ...". |
| `deletes.blockedReason` | String? | null | Set when deletes must stop for all rules (e.g. `PERMISSION_LOST`). |
| `stats.lastScanAt`, `stats.lastUploadAt`, `stats.lastCleanAt` | Long? | | |
| `stats.lastRunStopReason` | String? | | |
| `debug.timeWarp` | Bool | false | Debug builds only: retention in minutes. |

## File state machine
```
           scan
            |
            v
   +----> QUEUED ----------------------------> IGNORED   (rule off-scope: start date, type, rule deleted before upload)
   |        |   \
   |        |    +-----------------------------> GONE    (file vanished before upload)
   |        v
   |    UPLOADING --(network lost / stopped)--> QUEUED  (attempts unchanged)
   |        |
   |        +--(Telegram error)--> FAILED --(backoff time)--> QUEUED
   |        |                         |
   |        |                         +--(attempts >= max)--> SKIPPED --(person taps Try again)--> QUEUED
   |        v
   |    UPLOADED --(reply does not match)--> FAILED
   |        |
   |        v
   |    VERIFIED --(file changed on disk)--> CHANGED   (a new QUEUED row is made for the new version)
   |        |   \
   |        |    +--(file removed by the person)--> GONE
   |        v
   |    DELETED   (only through DeleteGate, only by Cleaner)
   +--- (Try again from SKIPPED)
```
Rules of the machine (`FileStateMachine.kt`, pure Kotlin, fully unit-tested):
- Every change of `state` goes through `FileStateMachine.transition(file, event, now)`, which returns the new row or throws `IllegalTransition`. DAOs do not write `state` directly except via this.
- Terminal states: `DELETED`, `IGNORED`, `GONE`, `CHANGED`.
- `DELETED` is reachable only from `VERIFIED`, only with event `DeletedByCleaner`, which only `Cleaner` creates after `DeleteGate` allowed it.
- `UPLOADING` found at app start (a crash or kill mid-upload) becomes `QUEUED` with `attempts` unchanged. If it had a `tgMessageId` saved, it becomes `UPLOADED` instead (the send finished, the save did not).
- Backoff: after attempt *n* the file waits `min(2^n minutes, 6 h)` plus up to 20% random. Flood-wait sets `nextAttemptAt` to at least now + `retry_after`.
- Network errors (no route, timeout, Wi-Fi lost) do not count as attempts. Telegram errors (4xx other than 429, mismatched reply) do. 429 does not count but waits. 5xx counts after the third in a row.

## Queue order
```sql
SELECT * FROM files
WHERE state = 'QUEUED'
   OR (state = 'FAILED' AND nextAttemptAt <= :now)
ORDER BY takenAt DESC, id DESC
LIMIT 1
```
plus filters: rule enabled; route usable now (account files only when `account.state = READY`); the network constraint. Newest first covers both new files and backlog, as the plan asks.

## The delete gate
`DeleteGate.check(file, rule, settings, disk, now): Allowed | Denied(reason)`. Pure function, no I/O (the caller passes the disk facts in). Allowed only if **all** hold:
1. `file.state == VERIFIED`, and `tgMessageId`, `tgChatId` are set.
2. `rule.mode == UPLOAD_AND_DELETE` and `rule.deleteWarningAcceptedAt != null`.
3. `rule.enabled`.
4. `settings.deletes.blockedReason == null`.
5. `now >= file.deleteAfter`.
6. The rule's `dryRun` is false, or this file is in a review the person approved.
7. Disk facts: the file exists, and its size and modified time equal the row's `sizeBytes` and `modifiedAt`.
8. Strong check: if the account is `READY`, it re-fetched the message just now and the content still matches. If the account is not ready, the M1 decision applies: either Denied(`NO_STRONG_CHECK`) or allowed on the bot reply alone.
9. Bot-only mode guard: `file.route == BOT` or the account check passed (an account-route file cannot be re-checked without the account).

Each denial reason is an enum value (`NOT_VERIFIED`, `RULE_UPLOAD_ONLY`, `NO_WARNING_ACCEPTED`, `RULE_OFF`, `DELETES_BLOCKED`, `NOT_DUE`, `NEEDS_REVIEW`, `FILE_MISSING`, `FILE_CHANGED`, `TELEGRAM_MISMATCH`, `NO_STRONG_CHECK`) with a test each.

## Deleting a rule
Rules are **soft-deleted**: `deletedAt` is set, `enabled` becomes false, and the rule disappears from lists. The row stays so History can still name it.
- Its `QUEUED`, `FAILED` and `SKIPPED` files become `IGNORED`.
- Its `UPLOADED`, `VERIFIED`, `DELETED`, `CHANGED` and `GONE` files are kept as they are.
- A soft-deleted rule never deletes files (gate condition 3 fails because it is disabled).
- The rule's name is freed for reuse (the unique index is on `name` where `deletedAt IS NULL`).

> **Built differences (2026-11-02):** Room cannot express the partial unique index on live rule names, so `RuleRepository` enforces it. New settings: `telegram.botProblem`, `delete.allowBotOnly` (owner decision D1, default false). The queue also hides a `QUEUED` row whose `nextAttemptAt` is in the future (flood-wait).

## Migrations
- Room `exportSchema = true`, schemas committed in `app/android/app/schemas/`.
- Every schema change bumps the version and adds a written `Migration` with a test (`MigrationTestHelper`). No destructive fallback in release builds: losing the database would lose which files are already backed up.

## Secrets (not in the database)
| Secret | Where |
|---|---|
| Bot token | `SecretStore`: AES-256-GCM, key in Android Keystore (`telebackup.secrets`), ciphertext in `files/secrets.bin` (no-backup dir). |
| `api_id`, `api_hash` | `SecretStore`. |
| TDLib database encryption key | `SecretStore` (random 32 bytes made on first login). |
| TDLib session | TDLib's own folder `no_backup/tdlib/`, encrypted with the key above. |
| Phone number | Not stored by us. TDLib keeps what it needs. UI shows a masked number from TDLib. |

The manifest sets `android:allowBackup="false"` and a `dataExtractionRules` file that excludes everything, so none of this goes to Google backup or a device-to-device transfer.

## Export file (rules only)
```json
{
  "format": "telebackup-rules",
  "version": 1,
  "exportedAt": "2026-11-01T10:00:00Z",
  "settings": { "rules.defaultRetentionDays": 7, "control.delayOptionsMinutes": "120,300", "network.allowMobileData": false },
  "rules": [
    { "name": "Screenshots", "folderPath": "Pictures/Screenshots/", "includeSubfolders": false,
      "mediaTypes": "BOTH", "topicName": "Screenshots", "uploadAs": "MEDIA",
      "mode": "UPLOAD_AND_DELETE", "retentionDays": 7, "startMode": "TODAY" }
  ]
}
```
No ids, no chat ids, no tokens. On import every rule becomes `UPLOAD_ONLY`, `enabled = false`, `dryRun = true`, and topics are matched by name or created.
