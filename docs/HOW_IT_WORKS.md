# teleBackup: how it works, end to end

What happens, step by step, in every situation the app has to handle. Names refer to `docs/DATA_MODEL.md` (tables, states), `docs/TELEGRAM.md` (sending), `docs/BRIDGE.md` (UI calls) and `docs/UI.md` (screens).

## 1. The parts
```
                +--------------------- phone ---------------------+
 person ------> | Flutter UI  --bridge-->  Kotlin core              |
                |                          |- RuleRepository         |
 notification<->|  ControlReceiver <-------|- StatusHub (StateFlow)  |
   buttons      |                          |- Scanner   (ScanWorker) |
                |                          |- Uploader  (UploadWorker, foreground) --> Telegram Bot API
                |                          |- Verifier                              --> TDLib (account)
                |                          |- Cleaner   (CleanWorker) -> DeleteGate -> FileDeleter
                |                          |- Notifier, SecretStore, EventLog
                |                          '- Room DB (telebackup.db)
                +--------------------------------------------------+
```
Workers (WorkManager, unique names so there is never more than one of each):
| Unique name | Kind | When | Constraints |
|---|---|---|---|
| `daily` | Periodic, 24 h, flex 6 h | Runs scan, then clean, then prunes events | battery not low |
| `scan-now` | One-time | Rule saved, Scan now, setup done | none |
| `upload` | One-time, `ExistingWorkPolicy.KEEP` | After any scan that queued files; on Resume; when a delay ends; when the account logs in; on app start if the queue is not empty | network: `UNMETERED`, or `CONNECTED` if mobile data is allowed |
| `resume-at` | One-time with initial delay | Delay 2h/5h | none |
| `clean-now` | One-time | Review approved, debug | none |
| `retry-at` | One-time with initial delay | Earliest `nextAttemptAt` of a `FAILED` file, if no upload is running | same as `upload` |

WorkManager keeps these across app kills and phone restarts, so there is no boot receiver.

## 2. First launch and setup
1. `MainActivity` starts the Flutter engine. The UI calls `getSettings()`. `setupDone == false`, so it shows O1, or the step in `app.setupStep`.
2. **O2 Permissions**: the UI calls `getPermissions()` on every resume and shows ticks. Buttons call `openAllFilesSettings()`, `requestBatteryExemption()`, or the Flutter notification permission request.
3. **O3 Bot**: `setBotToken(token)` -> core calls `getMe`. Ok: token stored in `SecretStore`, `telegram.botId/botUsername` saved, `BotInfo` returned. Wrong: `FlutterError(TELEGRAM, "That token did not work...")`.
4. **O4 Group**: `findGroups()` -> `getUpdates` -> list. Person picks one -> `checkGroup(chatId)` -> `getChat` + `getChatMember`. All green -> `selectGroup(chatId)` saves `telegram.chatId/chatTitle` and posts the hello message.
5. **O5 Account** (optional): S-LOGIN drives `accountStart -> accountPhone -> accountCode -> (accountPassword)`; each call returns at once and the new state arrives by `onTelegramState`. On `READY`, `account.state = READY`.
6. **O6 Suggested rules**: `suggestedFolders()` returns known folders that exist, with counts. `createSuggestedRules(paths, startMode, startDate)` creates one topic per rule (`createForumTopic`, paced) and one rule each, all `UPLOAD_ONLY`, `dryRun = true`.
7. **O7 Done**: `finishSetup()` sets `app.setupDoneAt`, schedules `daily`, and runs `scan-now`.

## 3. Adding or editing a rule
1. S-EDIT calls `previewRule(rule)` (debounced 300 ms) as fields change. The core runs the scanner in **count-only** mode for that folder and start date and returns count + bytes.
2. Picking "Delete from phone" opens D-DELETE-ON. Accepting sets `deleteWarningAccepted = true` in the form.
3. **Save** -> `saveRule(rule)`:
   - `RuleValidator` checks name (1-40, unique), folder exists and is readable, retention 1-365, delete invariant.
   - If `newTopicName` is set: `createForumTopic`, row in `topics`, `rule.topicId` set. If Telegram fails, nothing is saved and the error is shown.
   - Rule saved; `deleteAfter` recomputed for this rule's `VERIFIED` files if retention or mode changed.
   - `scan-now` for this rule.
4. Changing `uploadAs` or `topicId` affects only files not yet uploaded. Changing `startMode` to an earlier date queues the extra files at the next scan; moving it later turns not-yet-uploaded files before the new date into `IGNORED`.

## 4. The scan
`Scanner.scan(rule)` (inside `ScanWorker` or `scan-now`):
1. Skip if the rule is off or soft-deleted, or All files access is missing (then raise `PERMISSION_LOST`, see section 11).
2. Query MediaStore `Files` for the volume `external_primary`:
   - `RELATIVE_PATH = :folder` (or `LIKE :folder%` when including subfolders),
   - `MEDIA_TYPE` in image / video per `mediaTypes`,
   - `IS_PENDING = 0`, `IS_TRASHED = 0`,
   - columns `_ID, _DATA, DISPLAY_NAME, MIME_TYPE, SIZE, DATE_MODIFIED, DATE_TAKEN, WIDTH, HEIGHT, DURATION`.
3. If MediaStore returns nothing for a folder that has files (folders with `.nomedia`, or not indexed yet), fall back to a `java.io.File` listing filtered by extension and read size/dates from the file system. The scanner logs which path was used.
4. For each file:
   - newer than 2 minutes (`modifiedAt > now - 2 min`) -> skip for now (may still be being written);
   - `takenAt` before `rule.startDate` -> not inserted at all (keeps the table small; the backlog preview counts these as "not included");
   - identity `(ruleId, path, sizeBytes, modifiedAt)` already exists -> nothing to do;
   - same `path` exists with a different size or modified time:
     - old row `QUEUED`/`FAILED`/`SKIPPED` -> update it in place (it was never uploaded);
     - old row `VERIFIED` -> old row becomes `CHANGED`, new row `QUEUED` (the new version is uploaded; the old one is never deleted from the phone because the file on disk no longer matches it);
   - otherwise insert `QUEUED` with `route` from `Router`.
5. Rows `QUEUED`/`FAILED`/`SKIPPED`/`VERIFIED` whose file no longer exists -> `GONE` (the person deleted or moved it themselves). Checked only for paths under this rule's folder.
6. Write one `SCAN_DONE` event per rule ("Gallery photos: 41 new files"), set `stats.lastScanAt`.
7. If anything is queued, enqueue `upload` (KEEP, so a running upload is not restarted).

Large backlogs: inserts are batched (500 per transaction). The scan is cheap because hashing waits for upload time.

## 5. The upload run
`UploadWorker` is a `CoroutineWorker` that promotes itself to a foreground service (`setForeground` with type `dataSync`) before the first file.

Starting from the background is restricted on Android 12+. The app's battery-optimisation exemption is what allows it (a listed exemption from the background start rule), which is why O2 requires it. If Android still refuses (`ForegroundServiceStartNotAllowedException`), the worker returns `retry()` and logs `RUN_STOPPED(reason=fgs_not_allowed)`; Home shows "Backup could not start in the background. Open teleBackup once." **(M1 verifies this on the real phone.)**

The loop:
```
onStart:
  if control.state != RUNNING: return success        // paused or delayed
  recover: rows stuck in UPLOADING -> QUEUED (or UPLOADED if tgMessageId set)
  setForeground(progress notification)
  runFilesTotal = count(queue)

loop:
  if isStopped: break                                 // network lost, OS stop, time limit
  if control.state != RUNNING: break                  // Pause was pressed during the last file
  file = queue.next(now) ?: break                     // see DATA_MODEL "Queue order"
  if file.route == ACCOUNT and account.state != READY: mark "waiting account", continue to next BOT file
  if file missing on disk: transition GONE; continue
  if size/mtime changed since scan: update row (still QUEUED), continue
  pacer.awaitSlot(file.route)                         // 15/min for bot, gap for account
  transition UPLOADING
  file.sha256 = sha256(file.path)                     // streaming, 1 MB buffer
  result = sender(file.route).send(job(file), progress = notifier::update)
  when result:
    Sent    -> save tg* fields, transition UPLOADED
               verifier.checkReply(...)  Ok -> VERIFIED, set deleteAfter if rule deletes
                                         Mismatch -> FAILED (attempt +1), event VERIFY_FAILED
    Failed  -> apply TgError table (TELEGRAM.md): FAILED/QUEUED/SKIPPED, flood-wait, stop-the-run errors
  events + stats; runFilesDone++

onEnd:
  remove progress notification (or switch to Paused/Delayed notification)
  set stats.lastUploadAt, stats.lastRunStopReason
  if FAILED files have a future nextAttemptAt: enqueue retry-at at the earliest one
  return success
```
- The database write after each send is one transaction (tg fields + state + event), so a crash can only fall between "Telegram accepted" and "saved" (section 9).
- Only one file is in flight at a time.
- Hashing a 1 GB video takes a few seconds; it runs before the send, on the same thread.
- The notification is updated at most once a second (`Notifier` throttles).

## 6. Pause, Delay, Resume
Buttons on the notification send a `PendingIntent` broadcast to `ControlReceiver` (not exported, explicit intent). Home calls the same code through the bridge.

| Action | What the core does |
|---|---|
| **Pause** | `control.state = PAUSED`. Event `PAUSED`. The notification shows "Pausing after this file...". The worker finishes the current file (the loop checks the state between files), then ends. The notification becomes **Paused** with Delay/Resume buttons. If no upload was running, it only sets the state. |
| **Delay N** | `control.state = DELAYED`, `control.delayedUntil = now + N`. Enqueue `resume-at` with `initialDelay = N` (REPLACE). Notification **Paused until HH:MM**. Event `DELAYED`. |
| **Resume** | `control.state = RUNNING`, clear `delayedUntil`, cancel `resume-at`, enqueue `upload`. Event `RESUMED`. |
| `resume-at` fires | Same as Resume. If there is no Wi-Fi, `upload` simply waits for its network constraint; the paused notification is removed and Home shows "Waiting for Wi-Fi". |

Paused state survives restarts (it is in the database). While paused, the daily scan still runs and queues; nothing uploads.

## 7. Network changes
- **Wi-Fi lost mid-file**: WorkManager sees the constraint fail and stops the worker (`isStopped`, stop reason `CONSTRAINT_CONNECTIVITY`). The OkHttp call is cancelled, the file goes back to `QUEUED` with attempts unchanged, event `RUN_STOPPED(network)`. When Wi-Fi returns, WorkManager starts `upload` again by itself.
- **Wi-Fi present but no internet** (captive portal): sends fail with `Network` errors. After 3 network failures in a row the worker stops with reason `no_internet` and retries with WorkManager backoff (30 s, exponential).
- **Mobile data allowed**: constraint `CONNECTED`. Switching the setting re-enqueues `upload` with the new constraint (REPLACE only if no run is active; else at the end of the run).
- **Use mobile data once**: sets `network.mobileOnceUntilEmpty`, enqueues `upload` with `CONNECTED`. Cleared when the queue empties or the run stops for another reason.
- TDLib uploads resume at the part level after a drop. Bot uploads restart the file from zero (the Bot API has no resume); for files under 50 MB this is fine.

## 8. Time limits and the OS stopping the run
- Android 15+ allows a `dataSync` foreground service about 6 hours per 24 hours. At the limit, the system stops it; WorkManager reports stop reason `FOREGROUND_SERVICE_TIMEOUT`. The current file goes back to `QUEUED`, event `RUN_STOPPED(time_limit)`, Home shows "Done for today". `upload` is enqueued again with an initial delay of 1 hour; it succeeds once the window allows.
- Any other stop (memory, Doze maintenance window ending) is handled the same way: the file returns to `QUEUED`, WorkManager restarts later.
- On Android 14+, the person can swipe away the foreground notification. The upload keeps running; the notification comes back at the next update.

## 9. Crashes, kills and restarts
| What happens | Result |
|---|---|
| App swiped away from recents | The worker keeps running (it is a foreground service). |
| Process killed by the OS mid-file | At next start the row is still `UPLOADING` -> `QUEUED`. The file is sent again. If Telegram had already accepted it, there is a duplicate in Telegram (harmless, same `#tb` hash). |
| Killed after "Telegram accepted" but before the save | Same as above: one duplicate, no loss. |
| Killed after the save | Nothing lost; the row is `VERIFIED` (or `UPLOADED`, which re-runs the reply check from saved fields). |
| Phone restarts | WorkManager re-schedules everything. `upload` resumes when its network constraint is met. |
| "Force stop" in Android settings | Android cancels all of the app's jobs until the app is opened again. Home shows "last ran" so this is visible; the person must open the app once. Not a bug we can fix. |
| Database write fails (disk full) | The worker stops with reason `disk_full`; attention warning "Phone storage is full". Nothing is deleted. |

## 10. Retention and delete
`CleanWorker` runs inside `daily` after the scan, and as `clean-now` after a review is approved.
1. If `deletes.blockedReason` is set, or All files access is missing: do nothing (log once).
2. For each rule with `mode = UPLOAD_AND_DELETE`, enabled, not deleted:
   - Candidates: `state = VERIFIED AND deleteAfter <= now`, oldest first, at most 500 per run.
   - If `rule.dryRun` is true and there is no approved review: create a `reviews` row (`WAITING`) holding the candidates (`files.reviewId`), post the `reviews` notification, event `REVIEW_CREATED`. Delete nothing. Next rule.
   - Otherwise, for each candidate:
     1. Read disk facts (exists, size, modified time).
     2. If the account is `READY`: `AccountVerifier.recheck(file)`.
     3. `DeleteGate.check(...)` (all 9 conditions, `docs/DATA_MODEL.md`).
     4. Allowed -> `FileDeleter.delete(file)`: delete via MediaStore (`contentResolver.delete` on the item's uri) or `File.delete()` + `MediaScannerConnection.scanFile`, per the M1 finding. Then confirm the file is gone. Transition `DELETED`, `freedBytes = sizeBytes`, event `DELETED`.
     5. Denied -> event `DELETE_DENIED(reason)` once per file per reason. `FILE_CHANGED` and `FILE_MISSING` move the row to `CHANGED`/`GONE`. `TELEGRAM_MISMATCH` or message not found -> row back to `QUEUED` (upload again). Other reasons: leave it, try at the next clean.
3. `stats.lastCleanAt`, totals updated.

**Approving a review** (`approveReview`): review `APPROVED`, `rule.dryRun = false`, `clean-now` runs and deletes exactly the reviewed files (each still goes through the gate). If any reviewed file changed meanwhile, it is not deleted (gate) and the review is marked `STALE` for those.

`FileDeleter` is the only class in the codebase that calls a file or MediaStore delete. A test enforces this (TESTING.md).

## 11. Things that need the person
Each has one attention kind (UI.md section 8) and one fix. While the cause lasts:
| Cause | Detected by | Core behaviour |
|---|---|---|
| All files access revoked | `Environment.isExternalStorageManager()` checked at the start of every worker | `deletes.blockedReason = PERMISSION_LOST` (every rule acts as upload only), scans and uploads stop. Cleared automatically when it is granted again (checked on app resume and each worker start); event `PERMISSION_BACK`. |
| Account logged out | TDLib state, or an auth error from TDLib | `account.state = EXPIRED`. Account files wait; bot files continue. Deletes that need the strong check wait. |
| Bot token revoked / bot kicked | 401 / 403 | Bot sends stop; account sends continue. |
| Topic deleted in Telegram | 400 thread not found | That rule's uploads wait; others continue. Fix = `remakeTopic(ruleId)` creates a new topic and points the rule to it. |
| Notifications turned off | Checked on app resume | Home warning only (we cannot notify). Uploads still run. |
| Battery optimisation back on | Checked on app resume | Home warning. |
| Delete review waiting | `reviews` row `WAITING` | That rule deletes nothing until approved. |

## 12. The kill switch
`stopAllDeletes()`: in one transaction, every rule becomes `UPLOAD_ONLY`, `deleteAfter` cleared on their files, waiting reviews `DISMISSED`, event `KILL_SWITCH`. Uploads continue. Turning delete back on needs D-DELETE-ON again, per rule.

## 13. What "freed" means
- `freedBytes` on a file = its size when the Cleaner deleted it.
- Home "Freed so far" = sum over `DELETED` files. "Today" = deleted since local midnight.
- Upload-only rules free nothing; their files count as "Backed up".

## 14. A family member's phone
Exactly the same app and flow. Each person: own bot (BotFather), own group, own account login, own rules. Nothing is shared between phones; there is no server. The setup guide (M5/M7) is written so a family member can finish O1-O7 alone.

## 15. Uninstall and reinstall
- Uninstall deletes the database and secrets. Files in Telegram stay.
- After reinstalling and connecting the same group, the app does not know what was uploaded. Rules set to "Back up from: Everything" would upload old files again (duplicates). The setup screen O6 defaults to "Today on" for that reason, and S-TG shows a hint when the group already has teleBackup messages *(draft: only possible with the account; decide in M5)*.

## 16. Debug-only tools
In debug builds S-DEV can: run each worker now, show WorkManager states, inject Telegram errors, and turn on **time warp** (`debug.timeWarp`): retention counts minutes instead of days, so the full delete path can be tested in minutes. Release builds compile these out (`BuildConfig.DEBUG` guards plus a separate `debug` source set).
