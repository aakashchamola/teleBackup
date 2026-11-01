# teleBackup: UI plan

Every screen, dialog and notification in version 1, with the words it shows. Screen ids (`S-..`) are used by the phase docs in `docs/phases/`. The words here are the real copy unless marked *(draft)*.

## 1. Principles
- **Set up once, then forget it.** After setup the person should only open the app to check on it or change a rule. Day to day, the notification is the main UI.
- **Status first.** Every screen answers "is it working, and is anything waiting for me?" before anything else.
- **Never scary by surprise.** Deleting is the only risky action. It is off by default, needs a warning to turn on, and its first run is a review the person approves.
- **Plain short words.** No jargon like "MTProto", "worker" or "MediaStore" on screen. Say "your Telegram account", "backup", "the gallery".
- **One action per problem.** Each warning has one button that goes straight to the fix.

## 2. Look and feel
| Item | Choice |
|---|---|
| Design system | Material 3 (Flutter `useMaterial3: true`). |
| Colour | Dynamic colour from the wallpaper on Android 12+ (`dynamic_color` package). Fallback seed colour `#1565C0` (blue). |
| Theme | Light and dark, follows the system. |
| Status colours | Working = primary. Paused / delayed = tertiary. Needs attention = error. Done / freed = a fixed green `#2E7D32` (dark theme `#81C784`). |
| Type | System font (Roboto). Material 3 type scale; numbers on Home use `displaySmall`. |
| Icons | Material Symbols (outlined). No Telegram logo anywhere (it is not our brand). |
| App icon | A phone with an up-arrow into a cloud, on the seed colour. Adaptive icon (foreground + background layers). |
| Motion | Default Material transitions only. Progress bars animate; nothing else moves on its own. |
| Sizes | Touch targets at least 48 dp. Works from 320 dp wide and with font size up to 200%. |
| Language | English only in v1. All strings live in one file (`lib/ui/strings.dart`) so another language can be added later. |

## 3. Navigation map
```
First run:  O1 Welcome -> O2 Permissions -> O3 Bot -> O4 Group -> O5 Account (can skip) -> O6 Suggested rules -> O7 Done
                                                                                                          |
Main app (bottom navigation bar, 4 tabs) <----------------------------------------------------------------+
  Home (S-HOME) ........ status, controls, warnings, today's numbers
  Rules (S-RULES) ...... list -> Rule detail (S-RULE) -> Rule editor (S-EDIT)
                                                         |-> Folder picker (S-FOLDER)
                                                         |-> Topic picker (S-TOPIC)
                                       Rule detail -> Delete review (S-REVIEW)
  History (S-HIST) ..... events -> File detail (S-FILE)
  Settings (S-SET) ..... -> Telegram connection (S-TG) -> Account login (S-LOGIN)
                         -> Permissions (S-PERM)
                         -> Diagnostics (S-DIAG)
                         -> Developer (S-DEV, debug builds only)
```
- Routing: `go_router` with a `StatefulShellRoute` for the 4 tabs, so each tab keeps its scroll position.
- The setup flow (O1..O7) is shown when `app.setupDoneAt` is empty. Its steps can be reopened later from Settings.
- Tapping the upload notification opens Home. Tapping a "needs attention" notification opens the screen that fixes it (see section 8).
- Back from a tab root goes to Home; back from Home leaves the app.

## 4. First run (setup flow)
One step per screen. A step bar at the top ("Step 2 of 6"). **Next** is enabled only when the step is done, except where marked "can skip". Progress is saved after each step, so leaving and coming back resumes at the same step.

### O1 Welcome
```
+--------------------------------------+
|                                      |
|          [ app icon ]                |
|                                      |
|   Free up your phone, keep every     |
|   photo in your own Telegram.        |
|                                      |
|   teleBackup moves photos and videos |
|   from folders you pick into a       |
|   private Telegram group that only   |
|   you own. It can delete them from   |
|   the phone once they are safely     |
|   uploaded. You choose when.         |
|                                      |
|   Setup takes about 10 minutes.      |
|   You need the Telegram app on this  |
|   phone.                             |
|                                      |
|              [ Start setup ]         |
+--------------------------------------+
```

### O2 Permissions
Each row shows a status (granted = green tick, missing = button). All three must be granted for **Next**.
```
+--------------------------------------+
| Step 1 of 6                          |
| Permissions                          |
|                                      |
| [v] Notifications                    |
|     To show backup progress.         |
|                                      |
| [ ] All files access      [Allow]    |
|     To read your folders and delete  |
|     files only after they are backed |
|     up. Android opens a settings     |
|     page: turn on teleBackup there.  |
|                                      |
| [ ] Run in background     [Allow]    |
|     So Android does not stop the     |
|     backup. Pick "Allow" or "Don't   |
|     optimise" on the next screen.    |
|                                      |
|                         [ Next ]     |
+--------------------------------------+
```
- Notifications: runtime request (Android 13+). If refused twice, the button becomes **Open settings**.
- All files access: opens `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` for this package. Status re-checked when the app resumes.
- Run in background: `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Needed, not optional: it is what lets the background upload start on modern Android (see HOW_IT_WORKS section 5). On phones known to kill apps (Xiaomi, Oppo, Vivo, Realme, OnePlus, Samsung) a second line appears: "Your phone may also need **Auto-start** turned on. [How]" which opens a short maker-specific guide (filled in during M6).

### O3 Create your bot
```
+--------------------------------------+
| Step 2 of 6                          |
| Create your bot                      |
|                                      |
| A bot is a small Telegram helper     |
| that posts your photos. You make it  |
| yourself in 1 minute.                |
|                                      |
| 1. Open @BotFather   [Open Telegram] |
| 2. Send /newbot                      |
| 3. Pick any name, then a username    |
|    ending in "bot"                   |
| 4. BotFather replies with a token.   |
|    Copy it.                          |
|                                      |
| Bot token                            |
| [ 123456:ABC...           ] [Paste]  |
|                                      |
| (v) Connected to @family_photos_bot  |
|                                      |
|                         [ Next ]     |
+--------------------------------------+
```
- **Open Telegram** opens `https://t.me/BotFather` (Telegram app handles it).
- On paste or after typing stops for 1 s, the app checks the token (`getMe`). States: checking (spinner), ok ("Connected to @name"), wrong ("That token did not work. Copy it again from BotFather."), no internet ("No internet. Try again when online.").
- The token field is obscured after it is accepted, with a **Show** eye button.

### O4 Your group
```
+--------------------------------------+
| Step 3 of 6                          |
| Make your private group              |
|                                      |
| 1. In Telegram, make a new group.    |
|    Name it e.g. "My photos backup".  |
| 2. Group settings > turn on Topics.  |
| 3. Add @family_photos_bot to the     |
|    group, then make it an admin with |
|    "Manage topics" on.               |
| 4. Send any message in the group.    |
|                                      |
|              [ Find my group ]       |
|                                      |
| Found:                               |
| (o) My photos backup                 |
|     [v] Topics on  [v] Bot is admin  |
|     [v] Bot can manage topics        |
|                                      |
|                         [ Next ]     |
+--------------------------------------+
```
- **Find my group** reads the bot's recent updates and lists groups it was added to. Each found group shows three checks. A failed check shows its fix in one line, e.g. "Topics are off. Turn on Topics in the group settings, then tap Find again."
- Nothing found: "No group found yet. Make sure you added the bot and sent a message in the group in the last day. Then tap Find again."
- Order matters (turn on Topics *before* adding the bot), because turning on Topics changes the group's id. If the id changed, the app follows it automatically and says nothing.
- On **Next**, the app posts one message in the group's General topic: "teleBackup is connected. Each folder you back up gets its own topic here." That proves sending works.

### O5 Your Telegram account (can skip)
```
+--------------------------------------+
| Step 4 of 6                          |
| Big videos (50 MB and over)          |
|                                      |
| Bots can only send files under       |
| 50 MB. For bigger videos, and for a  |
| stronger check before anything is    |
| deleted, teleBackup can use your own |
| Telegram account.                    |
|                                      |
| Recommended.                         |
|                                      |
|          [ Log in to my account ]    |
|                                      |
|  Skip for now: big videos wait, and  |
|  [delete rule from M1 decision].     |
|                        [ Skip ]      |
+--------------------------------------+
```
- **Log in** opens S-LOGIN (section 6). Coming back logged in shows "(v) Logged in as Aakash (+91 ••••• ••123)" and **Next**.
- The last line depends on the M1 decision about bot-only deletes. Either "...and delete stays off until you log in" or "...and deletes use the bot's check only". M1 fills it in.

### O6 Suggested rules
```
+--------------------------------------+
| Step 5 of 6                          |
| What to back up                      |
|                                      |
| We found these folders on your       |
| phone. Each one gets its own topic.  |
| They all start in "upload only":     |
| nothing is deleted yet.              |
|                                      |
| [v] Gallery photos   DCIM/Camera     |
|     1,204 photos · 4.1 GB            |
| [v] Gallery videos   DCIM/Camera     |
|     88 videos · 9.7 GB               |
| [v] WhatsApp images                  |
|     3,511 images · 1.9 GB            |
| [v] WhatsApp video                   |
|     402 videos · 3.3 GB              |
| [v] Screenshots  Pictures/Screenshots|
|     640 images · 0.6 GB              |
|                                      |
| Back up from:                        |
| (o) Today on   ( ) Everything        |
|  ( ) Since a date...                 |
|                                      |
|                [ Create rules ]      |
+--------------------------------------+
```
- Folders not found on this phone are hidden. Counts come from a quick preview scan.
- "Back up from" applies to all ticked rules here; each rule can be changed later.
- **Create rules** creates the topics in the group (one per rule) and the rules, all **upload only**, retention = default (7 days).
- Every rule can be edited later, and a rule can be added for any folder.

### O7 Done
```
+--------------------------------------+
| Step 6 of 6                          |
| You're set                           |
|                                      |
| teleBackup scans once a day and      |
| uploads on Wi-Fi. You will see       |
| progress in the notification bar.    |
|                                      |
| First backup: 5,845 files, 19.6 GB.  |
| It starts now if you are on Wi-Fi.   |
|                                      |
| Nothing is deleted from your phone   |
| until you turn on delete for a rule. |
|                                      |
|              [ Go to Home ]          |
+--------------------------------------+
```

## 5. Main tabs

### S-HOME Home
```
+--------------------------------------+
| teleBackup                           |
+--------------------------------------+
| +----------------------------------+ |
| | (*) Backing up                   | |
| | 12 of 240 files · 1.2 GB left    | |
| | [#####-------------------]  5%   | |
| | IMG_20261101_093012.jpg          | |
| |                    [ Pause ]     | |
| +----------------------------------+ |
|                                      |
| (!) 3 big videos wait for your       |
|     Telegram account.       [Log in] |
| (!) Screenshots: 42 files ready to   |
|     delete. Check first.    [Review] |
|                                      |
| Today                                |
|  Uploaded   38      Freed   412 MB   |
|  In queue  202      Skipped     1    |
|                                      |
| Freed so far: 18.4 GB                |
|                                      |
| Last scan:  today 03:12              |
| Last upload: 2 minutes ago           |
|                                      |
| [ Scan now ]        [ Upload now ]   |
+--------------------------------------+
|  Home   Rules   History   Settings   |
+--------------------------------------+
```
**Status card**, one of these (first match wins, top to bottom):

| Status | Title | Line under it | Buttons |
|---|---|---|---|
| Not set up | Setup not finished | "Finish setup to start backing up." | Continue setup |
| Needs attention (blocking) | Backup stopped | The reason, e.g. "teleBackup lost All files access." | Fix |
| Uploading | Backing up | "12 of 240 files · 1.2 GB left" + bar + current file name | Pause |
| Pausing | Pausing... | "Finishing IMG_2041.jpg first." | (none) |
| Paused | Paused | "240 files waiting." | Delay 2h, Delay 5h, Resume |
| Delayed | Paused until 18:30 | "Resumes by itself." | Resume now |
| Scanning | Checking folders | "Gallery photos..." | (none) |
| Waiting for Wi-Fi | Waiting for Wi-Fi | "240 files ready. Starts when you are on Wi-Fi." | Use mobile data once |
| Stopped for today | Done for today | "Android limits background work. Continues in a few hours." | (none) |
| Up to date | All backed up | "Next check tonight." | (none) |

- The Delay button labels come from settings (`control.delayOptionsMinutes`, default 2h and 5h).
- **Use mobile data once** runs this queue on any network until it empties or the app is closed; it does not change the setting. A confirm dialog shows the size first (D-MOBILE).
- **Warnings** (the `(!)` rows) are the attention list from the core. Each has one action. Possible warnings:
  - Account login expired -> **Log in** (S-LOGIN)
  - Big videos wait (no account) -> **Log in**
  - All files access lost -> **Fix** (system settings)
  - Notifications off -> **Fix**
  - Battery optimisation back on -> **Fix**
  - Bot removed from group / not admin -> **Fix** (S-TG)
  - A topic was deleted in Telegram -> **Fix** (S-RULE of that rule: re-create topic)
  - Delete review waiting -> **Review** (S-REVIEW)
  - N files skipped this week -> **See** (S-HIST filtered to skipped)
- **Scan now** runs a scan of all enabled rules now. **Upload now** starts the queue now (still obeys the network setting; on mobile data without permission it shows the Waiting for Wi-Fi state).
- Numbers update live while the app is open (status events from the core), and refresh on resume.

### S-RULES Rules
```
+--------------------------------------+
| Rules                                |
+--------------------------------------+
| +----------------------------------+ |
| | Gallery photos             [on ] | |
| | DCIM/Camera · photos             | |
| | Topic: Gallery photos            | |
| | [Upload only] [Original file]    | |
| | 1,180 backed up · 24 in queue    | |
| +----------------------------------+ |
| +----------------------------------+ |
| | Screenshots                [on ] | |
| | Pictures/Screenshots             | |
| | [Upload & delete · 7 days]       | |
| | [Media]                          | |
| | 600 backed up · 31 deleted       | |
| | 9 waiting to delete              | |
| +----------------------------------+ |
| +----------------------------------+ |
| | WhatsApp video             [off] | |
| | Off. Nothing is scanned.         | |
| +----------------------------------+ |
|                                      |
|                          ( + Rule )  |
+--------------------------------------+
```
- The switch turns a rule on or off. Off means: not scanned, its queued files wait. Nothing is deleted while off.
- Chips: mode (**Upload only** / **Upload & delete · N days**) and form (**Media** / **Original file**). A rule whose deletes are blocked shows an error chip "Delete paused: <reason>".
- Tap a card -> S-RULE. **+ Rule** -> S-EDIT (new).
- Empty state: "No rules yet. A rule picks a folder and the topic it goes to." [ Add a rule ]

### S-HIST History
```
+--------------------------------------+
| History                       [Find] |
| [All] [Uploaded] [Deleted]           |
| [Skipped] [Problems]                 |
+--------------------------------------+
| Today                                |
|  ^ IMG_2041.jpg      Gallery photos  |
|    Uploaded · 3.2 MB · 09:41         |
|  x Screenshot_0931.png  Screenshots  |
|    Deleted from phone · 0.4 MB       |
|  ! VID_0012.mp4      Gallery videos  |
|    Skipped: Telegram refused it 5    |
|    times. Tap to retry.              |
|  - Paused for 2 hours · 08:10        |
| Yesterday                            |
|  o Scan: 41 new files · 03:12        |
|  ...                                 |
+--------------------------------------+
```
- Events newest first, grouped by day, paged (50 at a time, loads more on scroll).
- Filters as chips; **Find** searches file names.
- File events open S-FILE. App events (scan, pause, login expired) have no detail page.
- Kept for 90 days (`events` pruning), file rows are kept for ever.
- Empty state: "Nothing yet. Uploads and deletes will show up here."

### S-SET Settings
```
+--------------------------------------+
| Settings                             |
+--------------------------------------+
| Network                              |
|  Use mobile data             [off]   |
|  When off, uploads wait for Wi-Fi.   |
|                                      |
| Pause buttons                        |
|  Delay options          2h, 5h  >    |
|                                      |
| New rules                            |
|  Keep on phone after upload  7 days >|
|                                      |
| Telegram                             |
|  Bot, group and account          >   |
|                                      |
| Phone                                |
|  Permissions                     >   |
|  Background running              >   |
|                                      |
| Safety                               |
|  Stop all deletes now                |
|  Turns every rule to upload only.    |
|                                      |
| Rules                                |
|  Export rules        Import rules    |
|                                      |
| Help                                 |
|  Diagnostics                     >   |
|  Setup again                     >   |
|  About · version 0.1.0 (1)           |
+--------------------------------------+
```
- **Use mobile data**: turning it on shows D-MOBILE-SETTING ("Large backups can use a lot of data. Turn on?").
- **Delay options**: a list of durations (default 2h, 5h), add/remove, 1 to 4 entries, each 15 min to 24 h. These become the buttons on the paused notification and on Home.
- **Keep on phone after upload**: the default retention for *new* rules (1-365 days). Existing rules keep their own.
- **Stop all deletes now**: confirm dialog D-KILL, then every rule's mode becomes Upload only. Nothing else changes.
- **Export rules**: saves a JSON file of rules and settings (no secrets) via the system share sheet. **Import rules**: picks such a file; imported rules always arrive as Upload only and off.
- **Setup again**: reopens O2..O6 without losing rules.

## 6. Other screens

### S-RULE Rule detail
```
+--------------------------------------+
| <  Screenshots                [Edit] |
+--------------------------------------+
| Pictures/Screenshots · photos        |
| Topic: Screenshots   [Open in Tg]    |
| Upload & delete · keep 7 days        |
| Sent as: Media                       |
| Backing up from: 1 Nov 2026          |
|                                      |
|  In queue      24                    |
|  Backed up    600   (2.1 GB)         |
|  Waiting to delete 9                 |
|  Deleted       31   (freed 11 MB)    |
|  Skipped        0                    |
|                                      |
| [ Scan now ]                         |
| [ Check what would be deleted ]      |
|                                      |
| Recent files                         |
|  IMG_... Uploaded 09:41          >   |
|  ...                         [All >] |
+--------------------------------------+
```
- **Open in Tg** opens the topic in Telegram (`https://t.me/c/<id>/<topic>`).
- **Check what would be deleted** opens S-REVIEW in preview mode (nothing happens on approve there unless a review is actually waiting).
- **All >** opens S-HIST filtered to this rule.
- If the topic was deleted in Telegram: a warning row "This topic is gone in Telegram. [Make it again]".

### S-EDIT Rule editor (new and edit)
```
+--------------------------------------+
| <  New rule                  [Save]  |
+--------------------------------------+
| Name                                 |
| [ Screenshots                    ]   |
|                                      |
| Folder                               |
| [ Pictures/Screenshots         > ]   |
| [ ] Include folders inside it        |
|                                      |
| File types                           |
| (o) Photos and videos ( ) Photos     |
| ( ) Videos                           |
|                                      |
| Telegram topic                       |
| [ Screenshots (new)            > ]   |
|                                      |
| Send as                              |
| (o) Media: looks nice in Telegram,   |
|     but photos are made smaller.     |
| ( ) Original file: exact copy, full  |
|     quality, shows as a file.        |
|                                      |
| Back up from                         |
| (o) Today  ( ) Everything            |
| ( ) Since [ 1 Oct 2026 ]             |
| This adds 1,204 files (4.1 GB),      |
| newest first.                        |
|                                      |
| After upload                         |
| (o) Keep on phone (upload only)      |
| ( ) Delete from phone after          |
|     [ 7 ] days                       |
|                                      |
| [ Delete this rule ]                 |
+--------------------------------------+
```
- **Name** is required, unique, max 40 characters. It is also the default new topic name.
- **Folder** opens S-FOLDER. Required.
- **Send as**: default is Original file for camera folders (`DCIM/...`), Media for everything else (the plan's suggestion). The person can change it. Changing it later affects only files not yet uploaded.
- **Back up from**: the line under it is a live preview (count and size of files that would be queued). Changing it on an existing rule only adds files; it never removes files already queued or uploaded.
- **After upload**: picking "Delete from phone" opens D-DELETE-ON. If the person cancels, it goes back to Keep on phone.
- When delete is on, the editor also shows: "First delete needs your check. [v]" (the rule's dry-run flag; on by default, turned off after the first approved review, can be turned back on).
- **Save** validates, saves, creates the topic if it is new, and runs a scan of this rule. Errors appear under the field ("Pick a folder.", "This name is already used.").
- **Delete this rule** -> D-REMOVE-RULE.

### S-FOLDER Folder picker
```
+--------------------------------------+
| <  Pick a folder                     |
+--------------------------------------+
| Suggested                            |
|  DCIM/Camera              1,292      |
|  Pictures/Screenshots       640      |
|  WhatsApp Images          3,511      |
|  WhatsApp Video             402      |
|  Telegram Images (skip?)     12      |
|                                      |
| Browse                               |
|  / (phone storage)                   |
|   > Android                          |
|   > DCIM                             |
|   > Download                         |
|   > Pictures                         |
|   ...                                |
|                    [ Use this folder]|
+--------------------------------------+
```
- Suggested: known folders that exist on this phone, with photo+video counts. The Telegram app's own download folders are shown with a hint "(these came from Telegram already)".
- Browse: a simple tree of `/storage/emulated/0`, folders only, with the media count of each. `Android/data` and `Android/obb` are not shown (no access).
- Already used folders show "(used by Gallery photos)" but can be picked again (e.g. same folder, photos vs videos).

### S-TOPIC Topic picker
```
+--------------------------------------+
| <  Telegram topic                    |
+--------------------------------------+
| (o) New topic:  [ Screenshots    ]   |
|                                      |
| Topics made by teleBackup            |
| ( ) Gallery photos                   |
| ( ) Gallery videos                   |
| ( ) WhatsApp images                  |
|                                      |
| ( ) General (the group's main chat)  |
+--------------------------------------+
```
- A bot cannot list a group's topics, so this lists the topics teleBackup made (the `topics` table). If the account is logged in, topics made by hand in Telegram are listed too.
- Two rules may share a topic.

### S-REVIEW Delete review
```
+--------------------------------------+
| <  Check before deleting             |
+--------------------------------------+
| Screenshots                          |
| These 42 files are backed up and     |
| checked in Telegram. teleBackup will |
| delete them from this phone.         |
| Total: 18 MB                         |
|                                      |
| [img][img][img][img]                 |
| [img][img][img][img]                 |
| ...                                  |
| Tap a photo to see it and its        |
| Telegram message.                    |
|                                      |
| [ Not now ]   [ Looks right, delete ]|
+--------------------------------------+
```
- A grid of thumbnails (from the phone's own files), each tappable to S-FILE.
- **Looks right, delete** approves: the files are deleted now, and future deletes for this rule happen by themselves (dry-run flag off).
- **Not now** keeps the review waiting; the Home warning stays.
- In preview mode (from S-RULE) the button reads **Close** and nothing is approved.

### S-FILE File detail
```
+--------------------------------------+
| <  IMG_20261101_093012.jpg           |
+--------------------------------------+
| [ thumbnail, or "Deleted from phone" |
|   placeholder ]                      |
|                                      |
| Gallery photos · DCIM/Camera         |
| 3.2 MB · 4000 x 3000 · taken 1 Nov   |
| Sent as original file                |
|                                      |
| Found        1 Nov 03:12             |
| Uploaded     1 Nov 09:41             |
| Checked      1 Nov 09:41             |
| Deletes on   8 Nov (upload & delete) |
|                                      |
| [ Open in Telegram ]                 |
|                                      |
| Check code: a1b2c3d4e5f6             |
+--------------------------------------+
```
- The timeline lists each state the file reached, with time.
- Skipped files show the reason in plain words and a **Try again** button (puts it back in the queue with attempts reset).
- "Check code" is the short SHA-256 in the caption, so the person can search `#tb a1b2c3d4e5f6` in Telegram.

### S-TG Telegram connection
Shows bot (@name, ok/problem), group (title, Topics on, bot admin, can manage topics), account (logged in as / not logged in / expired). Buttons: **Check again**, **Change bot**, **Change group**, **Log in / Log out of account**. Changing bot or group shows D-CHANGE-TG ("Files already uploaded stay where they are. New uploads go to the new group. Topics will be made again.").

### S-LOGIN Account login
A small flow inside one screen, driven by the account state from the core:
```
1. "Get your app keys"           2. Phone number          3. Code              4. Password (only if 2FA)
   Open my.telegram.org [Open]      [ +91 98xxxxxx12 ]       Telegram sent a      [ ********** ]
   Log in, "API development         [ Send code ]            code to your         "Your Telegram
   tools", make an app (any                                  Telegram app.        cloud password."
   name). Copy api_id and                                    [ 1 2 3 4 5 ]        [ Log in ]
   api_hash.
   api_id   [ 1234567 ]
   api_hash [ ••••••••• ]
   [ Next ]
```
- Errors in plain words: "Wrong code.", "Code expired. [Send again]", "Wrong password.", "Too many tries. Wait 8 hours." (from the flood-wait value).
- Done: "Logged in as <name>." and back to the caller.
- **Log out** (from S-TG) confirms first; big files then wait again.

### S-PERM Permissions
The O2 list again with live status, plus "Background running" maker guide. Opened from warnings and Settings.

### S-DIAG Diagnostics
Read-only text: app version, Android version, phone model, permissions, battery exemption, last scan/upload/clean times and results, queue counts by state, last 50 errors (with secrets removed), WorkManager job states. **Copy** and **Share** buttons. Header: "No passwords, tokens or phone numbers are included." The redaction is tested (TESTING.md).

### S-DEV Developer (debug builds only)
Not in release builds. Used in M1-M6.
- Time warp: retention counted in **minutes** instead of days.
- Run scan / upload / clean worker now; show WorkManager states.
- Fake errors: next bot call returns 429 / 500 / network drop; next verify mismatches.
- Spike tools from M1 (raw bot calls, raw TDLib calls).
- Wipe database (with confirm).

## 7. Dialogs
| Id | When | Title | Text | Buttons |
|---|---|---|---|---|
| D-DELETE-ON | Picking "Delete from phone" for a rule | Delete from this phone? | "After a file is uploaded and checked, teleBackup deletes it from this phone after N days. Telegram will then have the only copy. If the Telegram group or account is lost, these files are gone. The first delete waits for you to check it." + checkbox "I understand Telegram keeps the only copy." | Cancel / Turn on delete (enabled after the checkbox) |
| D-REMOVE-RULE | Delete this rule | Delete rule "Screenshots"? | "Files on the phone and in Telegram are not touched. Files waiting in the queue for this rule are dropped." | Cancel / Delete rule |
| D-KILL | Stop all deletes now | Stop all deletes? | "Every rule becomes upload only. You can turn delete back on per rule." | Cancel / Stop deletes |
| D-MOBILE | Use mobile data once | Use mobile data? | "This uploads 240 files (1.2 GB) on mobile data." | Cancel / Use mobile data |
| D-MOBILE-SETTING | Turn on Use mobile data | Use mobile data for backups? | "Backups will run on any connection. Large videos can use a lot of data." | Cancel / Turn on |
| D-CHANGE-TG | Change bot or group | Change group? | see S-TG | Cancel / Change |
| D-LOGOUT | Log out of account | Log out of Telegram account? | "Videos of 50 MB and over will wait until you log in again." | Cancel / Log out |
| D-WIPE | Developer: wipe database | Wipe all teleBackup data? | debug only | Cancel / Wipe |

## 8. Notifications
Three channels. Ids are stable (changing them resets the person's settings for the channel).

| Channel id | Name shown | Importance | Used for |
|---|---|---|---|
| `uploads` | Backup progress | Low (silent, no badge) | The progress / paused / delayed notification |
| `attention` | Needs your attention | Default (sound) | Things only the person can fix |
| `reviews` | Delete checks | Default | "Check before first delete" |

**Progress notification** (`uploads`, id 1, the foreground-service notification):
```
teleBackup · Backing up                          [small icon: up-arrow]
12 of 240 · IMG_20261101_093012.jpg
[#####--------------------]
1.2 GB left
[ Pause ]
```
- Updated at most once per second, and on each file change.
- When the current file is 50 MB or more, the bar shows that file's bytes ("VID_0012.mp4 · 340 of 812 MB"); otherwise it shows files done.
- **Pause** -> text "Pausing after this file..." (no buttons), then the paused notification.

**Paused** (`uploads`, id 1, a normal notification once the service has stopped):
```
teleBackup · Paused
228 files waiting
[ Delay 2h ]  [ Delay 5h ]  [ Resume ]
```
- Up to 3 action buttons fit, so at most 2 delay options appear here (the first two from settings). All options appear on Home.

**Delayed** (`uploads`, id 1):
```
teleBackup · Paused until 18:30
Resumes by itself
[ Resume now ]
```
- When the delay ends and the upload starts, this turns back into the progress notification. If there is no Wi-Fi at that time, it is removed and Home shows "Waiting for Wi-Fi".

**When the queue ends**: the progress notification is removed. No "done" notification (the person asked for no noise).

**Attention** (`attention`, one id per kind so they replace, not stack):
| Kind | Title | Text | Tap opens |
|---|---|---|---|
| Login expired | Telegram account logged out | "Big videos are waiting. Log in again." | S-LOGIN |
| All files access lost | teleBackup can't reach your folders | "Backup and delete are stopped. Tap to allow again." | system settings page |
| Bot removed | teleBackup can't post to your group | "Add the bot back as admin." | S-TG |
| Topic gone | Topic "Screenshots" was deleted | "Tap to make it again." | S-RULE |
| Notifications off | (cannot be shown; Home warning only) | | |

**Review** (`reviews`):
```
Check before deleting
Screenshots: 42 files (18 MB) are ready to delete from your phone.
```
Tap opens S-REVIEW for that rule. Shown once per waiting review, not again daily.

## 9. Status words
The same thing is always called the same name, everywhere in the UI.

| Internal state | Words on screen |
|---|---|
| file `QUEUED` | In queue |
| file `UPLOADING` | Uploading |
| file `UPLOADED` | Uploaded (checking) |
| file `VERIFIED` | Backed up |
| file `VERIFIED` and due for delete | Waiting to delete (or "Deletes on 8 Nov") |
| file `DELETED` | Deleted from phone |
| file `FAILED` | Will try again |
| file `SKIPPED` | Skipped (tap to retry) |
| file `IGNORED` | Not backed up (outside the rule) |
| file `GONE` | Removed from phone by you |
| file `CHANGED` | Changed after upload (uploaded again as new) |
| rule mode `UPLOAD_ONLY` | Upload only |
| rule mode `UPLOAD_AND_DELETE` | Upload & delete · N days |
| upload as `MEDIA` / `ORIGINAL` | Media / Original file |
| control `PAUSED` / `DELAYED` | Paused / Paused until HH:MM |

## 10. Loading, empty and error patterns
- **Loading**: a thin progress bar under the app bar; content keeps its last value (no blank screens).
- **Empty**: one sentence on what will appear here, and one button if there is something to do.
- **Bridge error** (the core did not answer): a snackbar "Something went wrong. Try again." and the error is logged for Diagnostics. Never show stack traces.
- **Offline**: only setup steps need the internet in the UI; they say "No internet. Try again when online."

## 11. Shared widgets
| Widget | Used on |
|---|---|
| `StatusCard` | Home |
| `WarningRow` (icon, one line, one action) | Home, Rule detail |
| `StatTile` (label + number) | Home, Rule detail |
| `RuleCard` | Rules |
| `ModeChip`, `FormChip` | Rules, Rule detail |
| `EventTile` | History, Rule detail |
| `FileTimeline` | File detail |
| `StepScaffold` (step bar, title, body, Next) | O1-O7 |
| `CheckRow` (tick/cross + text + fix button) | O2, O4, S-TG, S-PERM |
| `SecretField` (obscured with eye) | O3, S-LOGIN |
| `SizeText` (formats bytes: "412 MB", "1.2 GB") | everywhere |
| `TimeText` ("2 minutes ago", "today 03:12", "8 Nov") | everywhere |

## 12. Accessibility
- Every icon-only button has a tooltip and semantic label.
- The status card is one semantic node read as "Backing up, 12 of 240 files, 1.2 gigabytes left".
- Colour is never the only signal: states also have an icon and words.
- Contrast: Material 3 roles only, no custom text colours on custom backgrounds.
- Tested with TalkBack on and with font size at maximum (M5).

## 13. Which milestone builds which screen
| Milestone | Screens and UI |
|---|---|
| M0 | Hello screen with a "ping the native side" result. |
| M1 | S-DEV spike tools only (plain buttons and text). |
| M2 | Tab shell (4 tabs, placeholders), S-RULES, S-EDIT, S-FOLDER, S-TOPIC (functional, plain styling). |
| M3 | S-HOME status card, controls and numbers; all `uploads` notifications; `attention` channel. |
| M4 | S-REVIEW, D-DELETE-ON, D-KILL, `reviews` notifications, S-RULE delete numbers, time warp in S-DEV. |
| M5 | O1-O7, S-TG, S-LOGIN, S-PERM, S-HIST, S-FILE, S-SET, S-RULE, all remaining dialogs, theme and polish to this document, empty/error states, accessibility pass. |
| M6 | S-DIAG, maker-specific background guides, "last ran" details, large-list performance. |
| M7 | App icon final, version in About, release build without S-DEV. |
