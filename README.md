# teleBackup

An Android app that frees phone storage. It moves new photos and videos from folders you choose into your own private Telegram group, checks they arrived, and only then deletes them from the phone. It runs in the background on Wi-Fi and shows progress in the notification bar like a system update, with Pause, Delay and Resume buttons.

Built for the owner and their family. Each person uses their own Telegram account, bot and group. There is no server and no shared data.

**Status:** planning done (1 Nov 2026), no code yet. Next step is M0 in [docs/ROADMAP.md](docs/ROADMAP.md): install the tools and run a hello-world on the owner's phone in debug mode.

## Read in this order
1. [docs/PLAN.md](docs/PLAN.md): what the app does and every decision made, with the reasons.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it is built.
3. [docs/ROADMAP.md](docs/ROADMAP.md): milestones, test plan, risks and things to check on a real phone.
4. [docs/SETUP.md](docs/SETUP.md): setting up a computer and connecting the phone.
5. [docs/SESSION_LOG.md](docs/SESSION_LOG.md): what was done, newest at the end.

## One-line summary of how it works
Daily scan finds new files per folder rule, queues them, uploads on Wi-Fi to the rule's topic, confirms with Telegram, waits the rule's retention days, then deletes from the phone.
