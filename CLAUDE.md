# teleBackup: start here

Android app (Flutter UI + native Kotlin background code) that offloads photos/videos from chosen phone folders to the user's own private Telegram group, then deletes them from the phone. Owner and family only, sideloaded APK. Read `README.md`, then `docs/PLAN.md`.

## Rules that always apply
- **Never delete a file from the phone unless its upload is confirmed** (see "Safe delete" in `docs/ARCHITECTURE.md`). A file that fails is skipped, never deleted. This is the one thing that cannot be undone.
- **Test with a throwaway Telegram group and a test folder first.** Real photo folders only after the owner says so. Every rule starts in upload-only mode.
- Never print or commit secrets: bot tokens, `api_hash`, phone numbers, Telegram sessions, signing keys. They live in the Android Keystore on the phone only. `.gitignore` blocks the usual files; check before every commit.
- Test on the owner's real phone in debug mode (`docs/SETUP.md`), not only an emulator. Background, notification and delete behaviour differs by phone.
- Do not start installs or large downloads (Flutter, Android SDK, TDLib) without saying so first.
- After each piece of work, append to `docs/SESSION_LOG.md`, commit and push. End commits with the `Co-Authored-By` line for the Claude model doing the work.
- Talk to the owner in plain, short words, outcome first.

## Where things are
- Product decisions: `docs/PLAN.md`. Design: `docs/ARCHITECTURE.md`, `docs/HOW_IT_WORKS.md`. Screens: `docs/UI.md`. Data and the delete gate: `docs/DATA_MODEL.md`. Telegram: `docs/TELEGRAM.md`. Flutter/Kotlin contract: `docs/BRIDGE.md`. Code rules: `docs/DEVELOPMENT.md`. Tests: `docs/TESTING.md`.
- What to build next: `docs/phases/` (one file per milestone, tick tasks as done). Milestones and risks: `docs/ROADMAP.md`.
- Starting a session: read this file, the current phase file, and the end of `docs/SESSION_LOG.md`; continue from the first unticked task.
- Do not install the toolchain on the shared work machine (owner's decision, 2026-11-01). Development happens on the owner's own computer.
- Repo lives at `~/PX4-Autopilot/src/project/teleBackup`. It is a separate project; do not mix it into flyMe.
