# Development phases

One file per milestone, done in order. Each has a goal, a "done when", numbered tasks with checkboxes (tick them as you go), the on-phone checks, and the wrap-up. The summary table is in `docs/ROADMAP.md`.

| Phase | File | In one line |
|---|---|---|
| M0 | [M0.md](M0.md) | Install Flutter, Android SDK, JDK 17 on the owner's computer; phone in USB debug; hello app pings Kotlin. |
| M1 | [M1.md](M1.md) | Spike on the real phone: bot + account uploads, reply checks, deletes, background survival. Answers go in `docs/M1_FINDINGS.md`. |
| M2 | [M2.md](M2.md) | Database, state machine, rules, scanner, Pigeon bridge, plain rule screens. |
| M3 | [M3.md](M3.md) | Background upload (bot + account), pacing, errors, progress notification, Pause/Delay/Resume, Home. |
| M4 | [M4.md](M4.md) | Delete gate, strong check, cleaner, first-delete review, kill switch, permission loss. |
| M5 | [M5.md](M5.md) | Every screen in UI.md, guided setup, history, settings, accessibility, family setup test. |
| M6 | [M6.md](M6.md) | Big backlogs, rate limits, phone-maker background kills, Android limits, crash recovery, diagnostics. |
| M7 | [M7.md](M7.md) | Signed APK, family guide, updates, roll-out. |

## Starting a phase (for a new session)
1. Read `CLAUDE.md`.
2. Read this phase's file and the docs it names under "Before you start".
3. Read the end of `docs/SESSION_LOG.md`.
4. Continue from the first unticked task.

## Owner checkpoints (ask, do not decide)
| When | Question for the owner |
|---|---|
| Start of M0 | Go for the installs (one "go" covers the M0 list). |
| M1 task C | Building TDLib from source (big download, long build) if no prebuilt works. |
| End of M1 | Decision D1: may a bot-only setup delete? |
| End of M4 | Start the one-week upload-only run on real folders? |
| End of M6 | Turn on real delete for Screenshots? |
| M7 | Make and back up the signing key; which family phone goes first. |
