# teleBackup: architecture

Two layers on one phone. No server.

```
Flutter UI  (screens: setup, rules, settings, history)
   |  platform channel
Kotlin core (everything that must run in the background)
   |- Scanner        finds files per rule (MediaStore + file system)
   |- Database       Room/SQLite: rules, files, settings
   |- Queue worker   WorkManager job, runs as a foreground service while uploading
   |- Uploaders      BotUploader (HTTP) and AccountUploader (MTProto)
   |- Verifier       confirms Telegram has the file
   |- Cleaner        deletes after retention
   |- Notifier       progress notification + Pause/Delay/Resume actions
   |- Secrets        Android Keystore
```

The UI only edits rules and settings and shows state. The Kotlin core keeps working when the UI is closed. The core must not depend on Flutter being alive.

## File life cycle (the state machine)

```
discovered -> queued -> uploading -> uploaded -> verified -> (retention wait) -> deleted
                 |          |           |
                 |          +-> failed (retry with backoff, then "skipped, shown in history")
                 +-> ignored (rule is off, older than start date, wrong type)
```

- State is stored per file in the database, so a crash, reboot or kill at any point resumes cleanly.
- A file reaches `deleted` only through `verified`. Nothing else can call delete.
- File identity: MediaStore id + path + size + modified time, and a SHA-256 computed before upload. The hash goes into the Telegram caption, which lets us spot duplicates after a crash between "sent" and "saved".

## Scanner
- Runs from a daily periodic job (WorkManager), plus once when a rule is added.
- Queries MediaStore by folder (bucket or relative path) and by type (image, video). Falls back to listing the folder for places MediaStore does not index.
- Skips files newer than ~2 minutes (still being written) and anything before the rule's start date.
- Backlog is queued **newest first**.

## Upload
- Sequential, one file at a time (maybe 2 later). Paced to stay under Telegram limits: a bot gets about 20 messages per minute into one group, so the pace is capped at ~15/min per group.
- **Route by size:** under 50 MB -> bot, at or over 50 MB -> account. Bot photos as "photo" must be 10 MB or less; larger ones go as a document or via the account.
- **Upload as media:** `sendPhoto` / `sendVideo` (video with streaming flag). **Upload as original:** `sendDocument`.
- Each message goes to the rule's topic (`message_thread_id`). The app creates the topics itself when the bot is admin with "manage topics".
- Caption (max 1024 chars): original filename, date taken, rule name, short SHA-256.
- Network drops or Wi-Fi loss: the current send fails, the file goes back to `queued`, and the job stops cleanly. Flood-wait replies from Telegram are obeyed, then retried.
- Network constraint: unmetered network by default. With "allow mobile data", any connected network.

## Safe delete (the rule that matters most)
A file counts as **verified** only when all of these hold:
1. The send call returned a message from Telegram (chat, topic, message id).
2. The returned message matches what we sent: for original files the byte size, for media the width/height (photos) or duration and width/height (videos).
3. The message id is stored in the database.

**Correction found while writing this:** a bot cannot read channel history, so it cannot "read the message back" later. Check 1 and 2 use the reply to the send itself, which is Telegram's own confirmation. When the owner's account is logged in, an extra check is possible: the account re-fetches the message by id just before delete. That is the strong check. The plan: use it whenever the account is set up, and make that the default recommendation in the setup guide. M1 decides if a bot-only setup is allowed to delete, or must stay upload-only.

Then, at delete time (retention days after upload), the Cleaner:
- re-checks the file on disk still has the same size and modified time as when it was uploaded (if changed, it is treated as a new file, never deleted),
- deletes it, then asks MediaStore to refresh so the gallery does not show a ghost,
- writes `deleted` and the time.

Dry-run mode (a setting, on for the first run of any rule) lists what would be deleted and deletes nothing.

## Notification and controls
- A foreground-service notification while uploading: title, "n of m files", bytes, progress bar, current file.
- Actions: **Pause**. When paused, the notification changes to **Delay 2h**, **Delay 5h**, **Resume**.
- Buttons send a broadcast to the core, which writes the state (running / paused / delayed-until) to the database. The worker checks that state between files.
- Pause: the current file finishes, then the queue holds. Delay: a one-time job fires at the chosen time and resumes.
- Android 13+ needs the notification permission. Android 14+ needs a declared foreground service type (data sync). Android 15 limits a data-sync foreground service to about 6 hours in a day; the worker must stop cleanly at that limit and resume in the next window.

## Scheduling
- Daily scan: periodic WorkManager job. Android decides the exact minute, so "daily" means roughly once a day, often at night when charging and idle.
- Upload job: starts when there is queued work and the network constraint is met; stops when the constraint is lost.
- The app asks the person to exempt it from battery optimization. Some makers (Xiaomi, Oppo, Vivo, Samsung and others) kill background apps more aggressively; this is tested in M6 on the family's phones.

## Telegram accounts
- **Bot:** created with BotFather by the person, token pasted once in setup. Added to the group as admin (post messages, manage topics).
- **Account (MTProto):** `api_id` / `api_hash` from my.telegram.org, then phone number + code (+ 2FA password). Library: TDLib (official, handles uploads, resume, flood-wait). Confirmed or replaced in M1.
- Secrets are encrypted with a key held in the Android Keystore. They are never written to logs or to the repo.

## Permissions
All files access (delete), media read, notifications, foreground service (data sync), network state, ignore battery optimization, internet.

## Data
Local SQLite database only. Tables: `rules`, `files`, `events` (for the history screen), `settings`. History screen shows what was uploaded, deleted, skipped and why. No analytics, no cloud.

## Testing approach
- Unit tests for the state machine, the pacing, and the "can this be deleted" decision.
- A fake Telegram server in tests for failures: flood-wait, 500s, a dropped connection mid-upload, and a reply that does not match.
- On the real phone: a test folder with a throwaway group, then real folders in upload-only, then delete.
