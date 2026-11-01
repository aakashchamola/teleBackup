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
