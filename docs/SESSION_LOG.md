# Session log

Newest at the end.

## 2026-11-01: planning
- Interviewed the owner about the idea (grill-me). Decisions written to `docs/PLAN.md`.
- Wrote `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `docs/SETUP.md`, `CLAUDE.md`, `.gitignore`.
- Name chosen: **teleBackup**. Repo: `aakashchamola/teleBackup` (private), on disk at `~/PX4-Autopilot/src/project/teleBackup`.
- Found while writing: a Telegram bot cannot read channel history, so "read the message back" is not possible with a bot alone. The delete check uses Telegram's reply to the send, plus an account re-fetch when the account is logged in. Recorded in ARCHITECTURE.
- Checked this computer: `adb` and Java 11 present; no Flutter, no Android SDK, no phone connected.
- No code yet. Next: M0 (install tools, connect the phone, hello-world).

## 2026-11-01: moved to the personal account
- Owner wants this kept apart from flyMe/Skyflock work (it is personal). Folder moved to `~/PX4-Autopilot/src/project/teleBackup`, which commits as aakashchamola. Repo is now `aakashchamola/teleBackup` (private). History was reset to one commit with that identity before the first push there.

## 2026-11-01: M0 start, held
- Re-read CLAUDE.md, PLAN, ROADMAP. M0 not started: no installs done.
- Owner said not to install Flutter, Android SDK or JDK 17 on this computer. Reason not given; note this computer's disk is 96% full (9.6 GB free), which would also have been tight. M0 is blocked until the owner picks a machine or frees space.
- Phone link chosen: USB cable (no phone detected on USB yet).
- Stray repo `skyflockuav/teleBackup`: not found under skyflockuav (7 repos listed, none is teleBackup). Owner dropped the deletion. The `skyflockuav` token has no `delete_repo` scope; nothing was deleted or changed.
- Next: owner decides where to install the toolchain, then M0 continues.

## 2026-11-01: full design and phase plans written
- Owner asked for the whole UI plan, how everything works, and every development phase written in advance, then pushed, so development can start on the owner's own computer after a pull.
- New docs: `UI.md` (every screen O1-O7 and S-*, dialogs, notifications, words, which milestone builds which screen), `HOW_IT_WORKS.md` (every situation step by step: setup, scan, upload loop, pause/delay, network, time limits, crashes, delete, attention cases), `DATA_MODEL.md` (tables, settings keys, state machine, delete gate with 9 conditions, migrations, secrets), `TELEGRAM.md` (routing, Bot API calls and errors, TDLib login/send/ids, captions), `BRIDGE.md` (Pigeon contract), `DEVELOPMENT.md` (repo layout, libraries, commands, code rules), `TESTING.md` (unit/widget/instrumented tests, test kit, device checks F1-F15), `phases/M0..M7.md` (step-by-step tasks with checkboxes), `M1_FINDINGS.md` (template).
- Refinements found while writing (recorded in ARCHITECTURE "Refinements"): media photos can't be size-matched; bots can't list topics (own `topics` table); battery exemption is required for background start; enabling Topics changes the group id; minSdk 30; allowBackup off.
- CLAUDE.md: points to the new docs; commit attribution line is now model-neutral; toolchain not installed on the shared work machine.
- Next: owner pulls on their own computer and starts `docs/phases/M0.md`.

## 2026-11-01: M0 on the owner's Windows PC
- Owner said to download whatever is needed and finish the whole development unattended. Installed JDK 17, Flutter 3.47.9, Android SDK (35/36) under `C:\Users\aakas\devtools`.
- `flutter create` app in `app/`; minSdk 30, manifest permissions, allowBackup off, hello screen + Kotlin `ping`. `flutter analyze`, `flutter test` and `flutter build apk --debug` pass.
- NOT done: running on the phone. No phone is connected (`adb devices` empty). The owner is out. Phone checks stay unticked until it is plugged in.
- Found: Java's downloader cannot reach the Gradle distribution here (curl can); workaround written in SETUP.md.
- Commit rule: no Claude co-author line (owner's standing rule); CLAUDE.md and DEVELOPMENT.md updated.
- Next: build the parts that need no phone (M2-M5 core and screens, tested on this PC); M1 phone/Telegram spikes wait for the phone and a throwaway Telegram group.

## 2026-11-01/02: built everything that needs no phone
- Owner (away) said: download what is needed, finish the whole development. Installed JDK 17, Flutter 3.47.9, Android SDK 35/36/37 under `C:\Users\aakas\devtools`.
- Kotlin core written and tested on the computer: file state machine (every state x event), delete gate (random 20,000-case check), router, pacer, captions, reply checks, redaction, scanner, upload loop, cleaner and reviews, kill switch, controls, rules, settings, status/warnings, export/import, diagnostics, folder catalog. Room database with all DAOs, tested on real SQLite via Robolectric. Bot API client and setup calls tested against a fake server. Secret store (AES-GCM, Android Keystore). Workers, scheduler, notifications, receiver. 201 JVM tests.
- Pigeon bridge and its Kotlin implementation. Flutter app: setup O1-O7, Home, rules (list/detail/editor/folder/topic), review, history, file, settings, Telegram, login, permissions, diagnostics, developer; FakeCore; 74 widget tests; analyzer clean.
- Release: signing refuses without the key, R8 rules, adaptive icon. Debug and release APKs build. On-phone tests written and compile.
- Found by tests and fixed on the way: a retry-due FAILED file was never moved back to QUEUED before upload; a short flood-wait ended the run early; button rows could overflow at large text; screens had no safe "back" when opened from a notification; a secret-store `delete()` tripped the one-door scan (now truncates).
- Not done: anything on the phone, all of M1's questions, TDLib/account path, owner decisions D1/D2, signing key. See `docs/STATUS.md`.
- Commit rule kept: no Claude co-author line.

## 2026-11-02 (the phone arrives)
- Phone connected (Moto G62, Android 13, 4 users: installs use `--user 0`). Bot Bot-API facts, account login, 75 MB and 1 GB account sends, Q6 re-fetch, resume after a network drop, hash speed: all measured and written in `M1_FINDINGS.md`.
- Built and tested on the phone: TDLib account path (community AAR 1.8.67), oldest-first queue, albums per day, document sorting per rule, Documents topic, notification fixes (clear at run end, survive overlapping runs), Room migrations 2 and 3, video splitting for files over 2 GB, scratch cleanup behind the one delete door.
- Release key made (`C:\Users\aakas\.telebackup\release.jks`, vault `TELEBACKUP_RELEASE_KEY_PASSWORD`); signed release build verified. Owner still has to back the .jks up.
- Gallery backup started on the owner's phone (upload-only, oldest first).

## 2026-11-03: iPhone version started (on the Mac)
- Installed Flutter 3.47.9 and CocoaPods; Xcode 26.6 selected. `flutter create --platforms=ios` added `app/ios`.
- New Swift package `app/ios/TeleCore`: models, state machine, delete gate, router, verifier, pacer, Bot API client, SQLite store, settings, rules, scanner, upload engine, cleaner (batched delete behind iOS's own prompt). 24 tests pass.
- Runner app code: Photos library source, exporter, batch deleter, Keychain, notifications with Pause/Delay/Resume, BGTasks, bridge implementation. Builds for simulator and device; launches in the iPhone 16 simulator.
- `tools/build_ios_ipa.sh` makes an unsigned .ipa for AltStore/Sideloadly (free Apple ID, 7-day signature). See docs/IOS.md.
- Open: test on a real iPhone; TDLib for videos over 50 MB; HEIC to JPEG for media uploads; document detector.

## 2026-11-03 (later): big videos on iPhone
- Account layer ported to TeleCore (login, sender, strong check, error mapping) with fake-gateway tests; the upload engine routes files of 50 MB and over through the account, the cleaner runs the strong check when the account is logged in. 32 core tests pass.
- New package `app/ios/TeleTD`: TDLib over its JSON interface. TDLibFramework 1.8.69-025086e3 is vendored in `app/ios/ThirdParty/TDLibFramework` (the binary is downloaded and SHA-256 checked by SwiftPM). A live test with dummy credentials reaches the phone step and maps Telegram's refusal to plain words.
- Wired into the app (login screens use the existing bridge calls); app builds and launches in the simulator; unsigned .ipa rebuilt (21 MB).
- Note: the macOS test process ends with signal 6 after the TDLib test passes (TDLib's receive thread at process exit); not seen in the app.
- Still to do: test on a real iPhone (photos, upload, delete prompt, TDLib login); document detector; HEIC to JPEG; videos over 2 GB.

## 2026-11-03 (later still): videos over 2 GB on iPhone
- Core: SplitPlan, VideoSplitter seam, album sending through the account, `sendInParts` in the upload engine (cut, album, verify each part, verified with no delete date, never offered for delete). Router cuts videos of 2 GB and over (max 10 parts). 37 core tests.
- TeleTD: `sendMessageAlbum` through TDLib (first failure drops the unsent parts so a retry starts clean).
- Runner: `AVVideoSplitter` (AVAssetReader/Writer pass-through, new part at the first keyframe after its share of the size). Checked on a generated 12 s video: 3 parts, all decode, 360 frames and 12.00 s in total.
- Not tested: a real 2 GB+ file on a real iPhone, and a real album upload.

## 2026-11-03 (night): HEIC photos, no documents on iPhone, self-care, Android-like notifications
- HEIC/HEIF in media rules are converted to JPEG (ImageIO) and sent as photos; fallback to the original as a file. Checked with a generated 4032x3024 HEIC.
- Documents sorting hidden on iPhone (rule switch, settings row); album names readable in the rules screen; "include subfolders" hidden.
- Self-care: retry loop inside the run, reconnect on Wi-Fi, delay expiry (in-app timer + background wake), WakePlanner (next retry / end of delay / daily) feeding BGTaskScheduler, daily housekeeping. 43 core tests.
- Notifications rewritten to match Android (progress, paused, paused until, warnings once each, check before deleting, routes on tap).
- Open: test on a real iPhone; the free-Apple-ID 7-day signature is the one thing that is not automatic (see docs/IOS.md).

## 2026-11-08: iPhone on the Mac (restore, background uploads, Dynamic Island)
- Installed on the owner's iPhone 15 in Release mode only (Debug apps cannot be opened from the home screen on iOS 14+). Signed with the free Personal Team, bundle id `com.anshulbhatt.telebackup`; install over the old app keeps its data. The signature lasts 7 days.
- Restore from Telegram: on the first run on a phone the account reads the group history, remembers each caption's file name + time taken (`restored` table); the scanner records matches as ignored ("Already in Telegram"), never uploads or deletes them. `HistoryRestorer`, `TdGateway.history`.
- Wake planner asks iOS for a window about a minute out while files wait (was a day).
- Background uploads: bot files go to iOS's background URLSession (`BackgroundUploader`, `UploadEngine.handOff` / `completeBackground`, table `bgjobs`, caps 600 MB / 150 files). The system keeps sending with the screen off and wakes the app when Telegram answers; the app then hands over the next files. Account (TDLib) files, 50 MB and over, still need the app to run.
- Dynamic Island / lock screen counter "done / total": widget extension `TeleBackupWidgets` + `Shared/BackupActivity.swift` + `LiveActivityController`. Starts while the app is open, updates whenever the app is awake.
- 53 core tests pass. Not yet proven on the phone with real photos: restore matching, background upload with the screen off, the Live Activity.

## 2026-11-08 (later): Live Activity fixes, Pause/Resume buttons, restore of queued files
- Live Activity: updates applied one at a time and never dropped; stays up while files are left (Wi-Fi wait, paused); stale marker after 10 minutes; Pause / Resume button on lock screen and expanded Dynamic Island (iOS 17+). Pause and Delay cancel uploads the system is carrying out and queue those files again.
- Smaller background batches (40 files / 300 MB) so iOS wakes the app more often. "Last upload" is written per confirmed upload; background completions also scan when the last scan is older than 5 minutes.
- Restore also marks files already queued before the history was read. Checked on the phone's database: 120 restored entries matched 120 verified files.
- 55 core tests pass.

## 2026-11-09: SideStore on iPhone 14/15 (iOS 17+) setup and pairing fixes
- Proven setup for SideStore on modern iOS: resolves the pairing file format ambiguity by splitting composite iloader exports into pure `PairingFile_RemoteRP.plist` (`tools/fix_pairing_file.py`).
- Fixes error `-80045` on iOS 17/18 by disabling broken On-Device Anisette and pointing to live remote server (`https://new.ani.sidestore.io`).
- Added complete iPhone 14/15 walkthrough in `docs/IOS_SIDESTORE_IPHONE14.md`. Allows running teleBackup completely computer-free without needing a Mac or keeping Xcode installed.

