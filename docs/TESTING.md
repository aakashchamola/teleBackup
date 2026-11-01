# teleBackup: testing

Three layers. The rule: anything that could cause a wrong delete has a test that tries to make it happen and expects it to fail.

| Layer | Where | Runs on | Speed |
|---|---|---|---|
| JVM unit tests | `app/android/app/src/test/` | the computer | seconds |
| Dart unit + widget tests | `app/test/` | the computer | seconds |
| Instrumented tests | `app/android/app/src/androidTest/`, `app/integration_test/` | the phone | minutes |
| Device checks (by hand, scripted with adb) | this file, section 5 | the phone + a throwaway Telegram group | per milestone |

## 1. JVM unit tests (Kotlin)
| Area | Test class | What it proves |
|---|---|---|
| State machine | `FileStateMachineTest` | Every allowed transition works; **every** other (state, event) pair throws. Generated table: all states x all events. `DELETED` reachable only from `VERIFIED` via `DeletedByCleaner`. Restart recovery: `UPLOADING` -> `QUEUED`, or `UPLOADED` when a message id is saved. |
| Backoff | `BackoffTest` | 2^n minutes capped at 6 h, jitter within 20%, flood-wait raises the floor, network errors do not count. |
| Delete gate | `DeleteGateTest` | One test per denial reason (11), each with all other conditions true. One "all true -> Allowed" test. A property-style test: random file/rule/settings combos; Allowed implies all 9 conditions hold. |
| Only one door | `DeleteCallsOnlyInFileDeleterTest` | Walks `src/main/kotlin`, fails if `.delete(`, `deleteRecursively`, `createDeleteRequest`, `Files.delete`, or `contentResolver.delete` appears in any file other than `core/clean/FileDeleter.kt`. (A string check; simple on purpose.) |
| State writes | `StateWritesOnlyViaMachineTest` | Same idea: `state =` / `SET state` only in `FileRepository` and `FileStateMachine`. |
| Rule validation | `RuleValidatorTest` | Name rules, retention bounds, delete invariant (`UPLOAD_AND_DELETE` needs the warning), import forces upload-only. |
| Scanner | `ScannerTest` (with `FakeMediaSource`) | Oldest first; start modes (today, since date, everything); skips files < 2 min old; identity dedupe; changed file -> `CHANGED` + new row; vanished -> `GONE`; subfolders on/off; photos/videos filter; MediaStore-empty fallback is used; batches of 500. |
| Router | `RouterTest` | 49.99 MB -> bot, 50 MB -> account; photo > 10 MB as media -> document; HEIC as media -> document; > 2 GB -> skipped; original -> document. |
| Pacer | `PacerTest` (fake clock) | <= 15 bot sends per rolling minute, burst 3; flood-wait blocks all routes for N s. |
| Caption | `CaptionBuilderTest` | Layout; 1024-char cap with a 300-char unicode name; no Markdown parsing issues with `_*[]`. |
| Bot client | `BotApiTest` (MockWebServer) | Request shape per method (multipart fields, `message_thread_id`, `disable_notification`); unicode file name; each error row in TELEGRAM.md maps to the right `TgError`; `migrate_to_chat_id` retry; progress callback reaches 100%; token never appears in any log line (captured `Tlog`). |
| Reply checks | `VerifierTest` | Document size match/mismatch; video duration +-1 s and rotated dimensions; photo aspect ratio rule; wrong chat/thread -> mismatch. |
| Upload loop | `UploadLoopTest` (fake senders, fake clock, in-memory DB via Room's JVM in-memory or a fake repo) | Pause between files; Delay sets resume; network stop returns file to `QUEUED` with attempts unchanged; account files wait while account not ready but bot files continue; time-limit stop; crash recovery; topic-missing pauses one rule only; bad token stops bot route only. |
| Cleaner | `CleanerTest` | Dry-run creates a review and deletes nothing; approved review deletes only reviewed files; changed file not deleted; strong check mismatch -> re-queued, not deleted; blocked reason -> nothing deleted; 500 cap. Uses a `FakeFileDeleter` that records calls. |
| Kill switch | `KillSwitchTest` | All rules upload-only, reviews dismissed, no deletes after. |
| Redaction | `TlogRedactionTest` | Bot tokens, 32-hex hashes, phone numbers (+91..., 10+ digits), 5-digit codes are masked; Diagnostics output contains none of the test secrets. |
| Settings | `SettingsRepositoryTest` | Defaults, bounds on delay options (1-4, 15-1440 min), unknown keys ignored. |
| Export/import | `RulesExportTest` | Round trip; no ids/tokens in output; import is upload-only and off. |
| TDLib ids | `TdIdsTest` | Bot API <-> TDLib message id conversion (values from M1). |

## 2. Dart tests
- Unit: formatting (`SizeText`, `TimeText`), status-card choice (UI.md table order), delay option parsing.
- Widget tests with `FakeCore` for every screen: renders each state in UI.md (status card variants, empty states, warnings), the D-DELETE-ON checkbox gate, the setup flow's Next enabling, the rule editor validation messages.
- Golden tests: not in v1 (they break on font changes; screenshots by hand in M5 instead).

## 3. Instrumented tests (on the phone)
| Test | What it proves |
|---|---|
| `MigrationTest` | Each Room migration from every old schema (from v2 on). |
| `MediaStoreSourceTest` | Creates files in `Pictures/teleBackupTest/` via MediaStore, scanner finds them with correct `takenAt`, size, dimensions. |
| `FileDeleterTest` | Deletes a test file it created; gallery (MediaStore) no longer lists it; a file outside the test folder is refused by the test harness guard. |
| `UploadWorkerTest` (work-testing `TestDriver`) | Constraints met -> runs; constraint lost -> stops and re-queues. Uses MockWebServer on the device as a fake Bot API (base URL overridable in debug builds only). |
| `SecretStoreTest` | Encrypt/decrypt round trip with the real Keystore; ciphertext file contains no plain token. |

## 4. The Telegram test kit
Throwaway only. Never the real group until M6/M7 and the owner says so.
- Group "teleBackup TEST" with Topics, a bot "…test_bot" as admin with Manage topics, the owner's account as a member.
- Test folder on the phone: `Pictures/teleBackupTest/` (and in M1/M4 a copy in the WhatsApp and Screenshots folders, deleted after).
- Files made by `tools/make_testkit.sh` (needs `ffmpeg` and ImageMagick on the computer):
  | File | Why |
  |---|---|
  | `small_01.jpg` ... `small_20.jpg` (1-3 MB, 4000x3000, with EXIF date) | normal photos |
  | `big_photo_12MB.jpg` | photo over the 10 MB bot photo limit |
  | `pano_12000x1000.jpg` | photo over sendPhoto's size/ratio limits |
  | `screen_01.png` | screenshot type |
  | `heic_01.heic` (copy one from the phone camera if it makes HEIC) | odd type |
  | `clip_30MB.mp4` (1080p, 2 min) | video by bot |
  | `clip_49_9MB.mp4` and `clip_50MB.mp4` | the 50 MB edge |
  | `clip_75MB.mp4` | video by account |
  | `clip_1GB.mp4` (1080p, ~20 min) | long upload, resume, time limits |
  | `rotated_portrait.mp4` | rotation metadata |
  | `ünïcödé name & spaces (1).jpg`, a 200-char name | names |
  | `IMG-20261101-WA0001.jpg` without EXIF | date from name (WhatsApp style) |
  Example commands (in the script): `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 300 -c:v libx264 -b:v 2M clip_75MB.mp4`; `convert -size 4000x3000 plasma: -quality 92 small_01.jpg` then `exiftool -DateTimeOriginal=...`.
- `tools/push_testkit.sh`: `adb push testkit/. /sdcard/Pictures/teleBackupTest/` then `adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/teleBackupTest/<f>` per file (or `adb shell content call --method scan_volume --uri content://media --arg external_primary` on newer Android) so MediaStore indexes them.

## 5. Device checks (by hand)
Run with the debug build, the throwaway group, and S-DEV time warp where useful. Record results in the phase file.

**Failure cases** (ROADMAP test plan, each one step-by-step):
| # | Do | Expect |
|---|---|---|
| F1 | Start upload of `clip_1GB.mp4`, then `adb shell svc wifi disable` | Run stops, file back to `QUEUED`, Home "Waiting for Wi-Fi"; `svc wifi enable` -> resumes by itself (account route resumes mid-file). |
| F2 | Mid-upload: `adb shell am kill com.aakashchamola.telebackup` (with the app in background) | Upload continues or restarts; no file lost; at most one duplicate message. |
| F3 | Mid-queue: `adb reboot` | After boot and Wi-Fi, upload resumes without opening the app. |
| F4 | Revoke All files access in settings | Attention notification; all deletes blocked; grant again -> `PERMISSION_BACK`, works again. |
| F5 | Change a file after it is backed up (`adb shell "echo x >> <file>"`) | Old row `CHANGED`, new version uploaded, old never deleted. |
| F6 | Rename a backed-up file | Old row `GONE`, renamed file uploaded as new (a duplicate in Telegram; accepted). |
| F7 | Delete the Telegram message of a backed-up file (as the account), then let it become due | Strong check fails -> not deleted, re-queued, uploaded again. |
| F8 | Wrong bot token (revoke in BotFather) | Bot route stops, attention "Bot problem"; account route continues. |
| F9 | Log out the account from another Telegram device (Settings > Devices) | `EXPIRED`, attention notification, big files wait. |
| F10 | S-DEV "next bot call returns 429 retry_after 30" | Everything waits 30 s, then continues; attempt count unchanged. |
| F11 | Delete the topic in Telegram | That rule waits with "Topic gone"; Make it again -> continues in the new topic. |
| F12 | Pause during a 1 GB upload | The file finishes, then paused; Delay 2h -> resumes ~2h later; Resume -> at once. |
| F13 | Screen off overnight on charger and on battery | Upload progresses; check heartbeat/`events` timestamps for gaps. |
| F14 | Android 15+: let a large backlog run > 6 h | Stops with "Done for today", resumes later by itself. |
| F15 | "Force stop" in app settings | Jobs stop until the app is opened (expected Android behaviour); Home shows last ran. |

**Delete safety** (M4): with time warp on, a rule in upload & delete on the test folder:
- First due batch -> review only, nothing deleted. Approve -> exactly those files deleted, gallery no longer shows them (check the Gallery/Photos app).
- A file not yet uploaded, an unverified file, a file in an upload-only rule, a changed file, a file whose message was deleted: none deleted after 3 clean runs (check on disk with `adb shell ls`).
- Kill switch during a clean: no deletes after it.

**Real folders** (only when the owner says so): one week upload-only on all real rules, then delete on Screenshots only, then widen one rule at a time (ROADMAP test plan 4-5).

## 6. Before each release (M7 checklist)
All JVM + Dart tests green; instrumented tests green on the owner's phone; F1-F15 re-run on the release build where they don't need S-DEV; one family phone run of setup O1-O7 by the family member alone.
