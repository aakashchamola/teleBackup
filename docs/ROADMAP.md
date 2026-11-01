# teleBackup: roadmap, tests and risks

Order matters. The first goal is to prove the risky parts on the real phone before building screens.

## Milestones

| # | Name | Done when |
|---|---|---|
| M0 | Tools and hello-world | Flutter and Android SDK installed. The owner's phone is connected in debug mode. A blank teleBackup app runs on it. |
| M1 | Proof of concept (the spike) | On the phone, in a test folder: one photo goes to a topic through the **bot**; one video over 50 MB goes through the **account**; the reply is checked; the file is deleted. Also answers the "check on device" list below. |
| M2 | Rules, database, scanner | Rules saved. The daily scan queues the right files, newest first. State machine tests pass. |
| M3 | Background upload and notification | Queue uploads on Wi-Fi in the background with the progress notification. Pause, Delay 2h/5h and Resume work. Wi-Fi loss and phone restart resume cleanly. |
| M4 | Verify and delete | Retention delete works, with dry-run. Nothing unconfirmed is ever deleted (tests try to force it). |
| M5 | Screens and family setup | Settings, rules list, history, guided Telegram setup (bot, group, topics, account login) a family member can finish alone. |
| M6 | Hardening | Large backlog (thousands of files), flood-wait, battery-optimization kills on each family phone, Android 15 foreground limit, crash recovery. |
| M7 | Family release | Signed APK, install and update steps, a short guide. iOS considered after this. |

## M1 questions to answer on the real phone
These are things I believe are true but have not proven on a device. M1 settles each one:
- Does deleting with "All files access" work for Gallery photos, **WhatsApp media** (`Android/media/com.whatsapp/...`) and Screenshots on this phone's Android version?
- After a delete, does the gallery still show the file until a MediaStore refresh?
- Does `sendVideo` keep the video bytes as they are (no recompression), and what does `sendPhoto` do to a full-resolution photo?
- Does the bot's reply give enough to match the file (size, dimensions, duration)?
- Which MTProto library works on Android with Flutter: TDLib prebuilt artifact or a build we make ourselves?
- Can the account re-fetch a message the bot posted, so it can act as the strong delete check?
- Does the foreground service survive the screen being off for hours on this phone?

## Test plan
1. **Safe place first.** A throwaway Telegram group with Topics, a bot, and a test folder with copies of a few photos and videos (small, large, odd names, unicode, a 1 GB video).
2. **Failure cases** (forced on purpose): turn Wi-Fi off mid-file, kill the app mid-upload, reboot mid-queue, revoke storage access, change a file after upload, rename a file, delete the Telegram message, wrong bot token, expired login, a flood-wait reply.
3. **Delete safety:** a test that tries every route to delete an unverified file and expects it to fail.
4. **Real folders in upload-only** for a week before any real delete.
5. **Real delete** on one rule first (screenshots), then widen.

## Risks
| Risk | Plan |
|---|---|
| Telegram limits or bans an account that uploads a lot | Account used only for big files, paced, no parallel bursts. Bot does the bulk. If the account is limited, files over 50 MB wait and nothing is deleted. |
| Telegram is the only copy | Owner accepted. Warning on enabling delete, upload-only by default, strong check via account. |
| Phone maker kills the background job | Battery exemption prompt, per-phone testing in M6, "last ran" shown in the app. |
| Android 15 six-hour foreground limit | Worker stops cleanly and resumes next window. |
| Crash between "sent" and "saved" posts a duplicate | Hash in caption; duplicates are harmless, never a loss. |
| Photo recompressed by Telegram and original deleted | Per-rule "original file" option; default suggestion for Gallery. |
| All files access is refused or revoked | Notify the person, switch every rule to upload-only until fixed. |
| A shared family phone number or login mistake | Each person sets up their own bot, group and account. |
