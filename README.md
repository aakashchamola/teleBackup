# teleBackup

An Android app that frees phone storage. It moves new photos and videos from folders you choose into your own private Telegram group, checks they arrived, and only then deletes them from the phone. It runs in the background on Wi-Fi and shows progress in the notification bar like a system update, with Pause, Delay and Resume buttons.

Built for the owner and their family. Each person uses their own Telegram account, bot and group. There is no server and no shared data.

**Status:** planning and full design done (1 Nov 2026), no code yet. Next step is M0 ([docs/phases/M0.md](docs/phases/M0.md)) on the owner's own computer: install the tools and run a hello-world on the owner's phone in debug mode.

## Read in this order
1. [docs/PLAN.md](docs/PLAN.md): what the app does and every decision made, with the reasons.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it is built (overview).
3. [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md): what happens, step by step, in every situation.
4. [docs/UI.md](docs/UI.md): every screen, dialog and notification, with the words they show.
5. [docs/DATA_MODEL.md](docs/DATA_MODEL.md): database, file states, the delete gate.
6. [docs/TELEGRAM.md](docs/TELEGRAM.md): bot and account (TDLib) details, errors, limits.
7. [docs/BRIDGE.md](docs/BRIDGE.md): the Flutter <-> Kotlin contract.
8. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): code layout, libraries, commands, rules for the code.
9. [docs/TESTING.md](docs/TESTING.md): tests, test kit, device checks.
10. [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/phases/](docs/phases/README.md): milestones, then one step-by-step file per milestone (M0-M7).
11. [docs/SETUP.md](docs/SETUP.md): setting up a computer and connecting the phone.
12. [docs/M1_FINDINGS.md](docs/M1_FINDINGS.md): answers found on the real phone (filled in M1).
13. [docs/SESSION_LOG.md](docs/SESSION_LOG.md): what was done, newest at the end.

## One-line summary of how it works
Daily scan finds new files per folder rule, queues them, uploads on Wi-Fi to the rule's topic, confirms with Telegram, waits the rule's retention days, then deletes from the phone.
