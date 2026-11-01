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
