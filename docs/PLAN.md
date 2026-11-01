# teleBackup: plan and decisions

Planned 2026-11-01 by interview (grill-me). Every line below is a decision the owner made or agreed to, with the reason.

## The problem
Phone storage keeps filling with photos and videos. The owner wants them moved to Telegram automatically, in the background, without thinking about it, and removed from the phone only once they are safely uploaded.

## Who it is for
The owner and their family. Sideloaded APK, no Play Store. Each person uses their **own** Telegram account, bot and private group, set up by a guided screen in the app. Nothing is shared and there is no server to run.

## What it does
1. You add **folder rules**. Each rule has: a folder on the phone, a Telegram topic, a mode, retention days, an "upload as" setting and a start date.
2. Once a day the app **scans** the folders and queues new files.
3. The queue **uploads on Wi-Fi** (mobile data only if you allow it in settings).
4. After Telegram confirms a file, it is marked uploaded.
5. When the file has been on the phone for the rule's **retention days after upload**, the app deletes it (only in "upload and delete" mode).
6. A notification shows progress. Buttons: **Pause**, then **Delay 2h**, **Delay 5h**, **Resume**.

## Decisions

| Area | Decision | Why |
|---|---|---|
| Platform | Android only for now. iOS later, as a reduced version. | iOS cannot run long background uploads or delete photos without a prompt each time. |
| Tech | Flutter for screens, native Kotlin for background work. | The owner chose cross-platform. Background work, notifications and file deletion still have to be native Android code. |
| Telegram access | Both: a **bot** for files under 50 MB, the owner's **account (MTProto)** for bigger files. | Bot is safe for the account but capped at 50 MB per file. Phone videos are often larger. The account is used only when needed, so ban risk stays low. |
| Destination | One private **group with Topics turned on**, one topic per rule. | Keeps WhatsApp, screenshots, gallery photos and videos separate. (Telegram "channels" do not have topics, groups do.) |
| Topics | Gallery photos, Gallery videos, WhatsApp images, WhatsApp video, Screenshots. More can be added as rules. | Owner's list for now. |
| Folders | Several folders, each with its own rules. | Different folders need different handling. |
| Upload form | Per rule: **media** (compressed, shows nicely in Telegram) or **original file** (exact bytes). Owner decides per rule later. Suggested: originals for Gallery, media for WhatsApp and screenshots. | Telegram recompresses photos sent as media, and the original is then deleted, so quality loss is permanent. The owner wants the choice. |
| Retention | Days to keep on the phone **after upload**. Default set in app, customizable per rule. Mode **upload only** never deletes. | Gives a window to view recent photos locally and never deletes before upload. |
| Triggers | A **daily** job scans and queues. The upload itself runs on **Wi-Fi only** by default. A setting allows mobile data. An unfinished queue resumes the next time Wi-Fi connects. | Owner's wording: the daily trigger decides what to upload today, the upload is Wi-Fi only unless allowed. |
| Backlog | Per folder, choose a start date ("from today", "since a date", "everything"). Backlog goes **oldest first** (owner's choice), at a gentle pace. | Frees recent space first and avoids Telegram rate limits. |
| Delete permission | "All files access" (grant once). | Silent deletes in the background. Not allowed on Play Store, which does not matter for a sideloaded family app. |
| Safe delete | Delete only after the upload is **confirmed** (see ARCHITECTURE). Files that fail are skipped, never deleted. | Deleting is the one step that cannot be undone. |
| Only copy | Telegram holds the only copy after delete. Accepted. Safeguards: private group you own, a one-time warning when you turn on delete mode, **every rule starts as upload only**. | Owner accepts the risk. |
| Pause | Pause lets the **current file finish**, then holds the queue. Delay 2h / 5h sets a timer then resumes. Resume restarts at once. Delay options editable in settings. | Simple and safe, no half-uploaded files. |
| Failures | Retry quietly with backoff. A failing file is skipped and listed in history. Notify only for things the person must fix: login expired, permission lost. | Thousands of files would make per-file alerts useless. |
| Retrieval | Version 1: use the **Telegram app** to browse. No restore, no gallery in teleBackup. Captions carry filename and date. | Keeps scope small. |
| Distribution | Sideloaded APK, own private GitHub repo `aakashchamola/teleBackup` (personal, kept apart from flyMe and Skyflock), at `~/PX4-Autopilot/src/project/teleBackup`. | Family only. |
| Testing | Owner's real phone in debug mode (cable or wireless debugging), throwaway Telegram group, test folder. | Background and delete behaviour differ by phone. |

## Not in version 1
Restoring files to the phone, an in-app gallery, iOS, a second backup copy (Drive, S3), video compression on the phone, Play Store release.

## Open items (to settle while building)
- Default retention days (suggest 7).
- The default Delay buttons are 2h and 5h as asked; whether to add more is a settings question.
- Which MTProto library to use on Android (TDLib is the leading choice; confirmed in M1).
- Family setup guide wording (M5).
