# teleBackup: the complete guide

teleBackup is an Android app that moves your photos and videos from folders on your phone into **your own private Telegram group**, checks that every file really arrived, and, only if you turn that on, deletes the phone's copy later so the space comes back. There is no server and no company in the middle: your files go from your phone to your Telegram, and nowhere else.

This guide covers everything: installing, the first setup, daily use, every setting, how deleting works, and what to do when something goes wrong. Version 1.0.0.

- [What you need](#what-you-need)
- [1. Install](#1-install)
- [2. First setup (about 10 minutes)](#2-first-setup-about-10-minutes)
- [3. What happens after setup](#3-what-happens-after-setup)
- [4. The four tabs](#4-the-four-tabs)
- [5. Rules, one by one](#5-rules-one-by-one)
- [6. Deleting from your phone](#6-deleting-from-your-phone)
- [7. Finding and restoring your files](#7-finding-and-restoring-your-files)
- [8. Settings](#8-settings)
- [9. Updating, moving phones, uninstalling](#9-updating-moving-phones-uninstalling)
- [10. If something is wrong](#10-if-something-is-wrong)
- [11. Safety rules built into the app](#11-safety-rules-built-into-the-app)
- [12. Privacy](#12-privacy)
- [13. Known limits](#13-known-limits)

---

## What you need
- An Android phone, **Android 11 or newer**, 64-bit (nearly every phone sold in the last eight years).
- The **Telegram app** on that phone, with your account logged in.
- About 10 minutes for the first setup. After that you can forget about it.
- Wi-Fi for the first big upload. A gallery of 10 GB takes several hours; it carries on by itself.

You will make three small things yourself, all free: a **bot** (a Telegram helper that posts your files), a **private group** with Topics turned on, and, for big videos and the safest delete check, an **app key** from Telegram's developer page. The app walks you through each one.

---

## 1. Install

1. On the phone, open the project's **Releases** page on GitHub (github.com/aakashchamola/teleBackup/releases) while logged in to GitHub, and download **teleBackup-1.0.0-arm64.apk** from the newest release. (The repository is private, so you must be logged in with the account that owns it, or one it was shared with.)
2. Open the downloaded file. Android asks to allow installing from this source (your browser or Files app). Allow it, then tap **Install**. Android may say the app is from an unknown developer; that is expected, the app is not in the Play Store.
3. Open **teleBackup**.

Optional check that the file is the real one: the release page lists the file's **SHA-256**. On a computer, `sha256sum teleBackup-1.0.0-arm64.apk` (or `certutil -hashfile teleBackup-1.0.0-arm64.apk SHA256` on Windows) must print the same text.

If Android says the app is "not compatible", your phone is older than Android 11 or is 32-bit; this version does not support it.

---

## 2. First setup (about 10 minutes)

The app shows **Step 1 of 6** and so on. Your progress is saved after every step; if you leave, you come back to the same step.

### Welcome
Read it and tap **Start setup**.

### Permissions
All three are needed, and the app shows a green tick for each when done.
- **Notifications**: so you can see progress and use the Pause button.
- **All files access**: Android opens a settings page. Turn on teleBackup there. Without it the app cannot read your folders, and it can never delete anything.
- **Run in background**: choose **Allow** or **Don't optimise** so Android does not stop the backup when the screen is off.

Some phone makers (Xiaomi, Oppo, Vivo, Realme, Samsung, Motorola and others) also have an **Auto-start** or **Battery > Unrestricted** switch in their own settings. If the app shows a line about it, tap **How** and follow it. Without it, a restart of the phone can stop the daily backup.

### Create your bot
A bot is a small Telegram helper that posts your files into your group. You make it yourself in a minute:
1. Tap **Open Telegram**, find **@BotFather** (the official one, blue tick).
2. Send `/newbot`.
3. Pick any name, then a username that ends in `bot`.
4. BotFather replies with a **token** (a long text with a colon in it). Copy it.
5. Back in teleBackup, tap **Paste** (or paste into **Bot token**). It says **Connected to @yourbot** when it works.

Keep the token private. Anyone with it can post as your bot. The app stores it in the phone's secure storage only.

### Make your private group
1. In Telegram make a **new group**. Name it anything, for example "My photos backup". Only you need to be in it.
2. Open the group's settings and turn on **Topics**. (Each backed-up folder gets its own topic, like a labelled shelf.)
3. Add your bot to the group, then make it an **admin** with **Manage topics** switched on.
4. Send any message in the group.
5. Back in teleBackup, tap **Find my group**.

The app checks three things and tells you which one to fix: **Topics on**, **Bot is admin**, **Bot can manage topics**. If it says no group was found, make sure the message was sent in the last day and tap **Find** again.

### Your account (optional now, strongly recommended)
Bots can only send files **under 50 MB**, and a bot cannot re-read what it sent. Logging in with your own Telegram account fixes both:
- videos of any size up to 2 GB go up directly (a video over 2 GB is cut into parts, see section 3);
- before anything is deleted, the app asks your account to fetch the message again and confirm it is really there. **Delete does not work without this login** (section 6).

To log in:
1. Tap **Log in to my account**. Tap **Open my.telegram.org**, log in with your phone number there, choose **API development tools**, and make an app (any name and short name). Copy the **api_id** (numbers) and **api_hash** (letters and numbers).
2. Paste both into teleBackup and tap **Next**. These are *your* app keys; the app stores them in secure storage and uses them only to talk to Telegram.
3. Enter your phone number with the country code (for example `+91 98765 43210`) and tap **Send code**.
4. Telegram sends a code, usually **inside the Telegram app** (not as an SMS). Type it and tap **Next**. If you have a cloud password (two-step verification), enter it.
5. It says **Logged in as ...**.

You can tap **Skip** and do this later from Settings > Telegram. Until you log in, big videos wait and delete stays off.

### What to back up
The app lists folders it found (Camera, Screenshots, WhatsApp images and so on). Each ticked folder becomes a **rule** with its own topic. Every rule starts as **Upload only**: nothing is deleted.

Choose how far back to go:
- **Today on**: only photos taken from now on. Your old photos are left alone.
- **Everything**: the whole folder, oldest first.
- **Since a date...**: from a day you pick.

Tap **Create rules**. The app makes the topics in your group, and a "You're set" screen appears. **Nothing is deleted from your phone until you turn on delete for a rule.**

---

## 3. What happens after setup

- **Once a day** (during the night, on Wi-Fi, ideally while charging) the app scans your folders, queues new files, uploads them, and checks them. You can also press **Scan now** and **Upload now** on Home.
- **Order**: oldest first, so a big old gallery fills your group from the beginning of time forward.
- **Wi-Fi only** by default. Turn on mobile data in Settings if you want, or press **Use mobile data once** on Home.
- **A day's photos arrive together** as an album of up to 10, so the group reads like a diary. You can turn this off in Settings > Sending.
- **Photos and videos in separate topics** if you make two rules (for example **Gallery photos** and **Gallery videos**).
- **Photos of documents** (paper, bills, forms, ID cards, handwritten notes) can go to a separate **Documents** topic, even when they came from the Gallery folder. You switch this on or off per rule (section 5). The detector runs on the phone, offline, and it is right most of the time, but not always: it sometimes sends a shop sign to Documents and misses an ID card held in a hand.
- **Videos over 2 GB** are cut into parts at a natural break (no re-encoding, no quality loss) and sent as one album of parts, each checked on its own. The app needs free space on the phone equal to the video size while cutting, and it cleans up its temporary parts afterwards. Video formats the phone cannot cut (mkv and some others) and videos that would need more than 10 parts are skipped, with the reason shown. **The app never deletes a video that was sent in parts** (section 11).
- **The notification** shows the current file and counts like a system update, with **Pause**. When paused you get **Delay 2h**, **Delay 5h** and **Resume**. When everything is done the notification disappears.
- **After a restart** of the phone the app wakes itself up and carries on.
- **Media vs original**: a rule can send files "as media" (looks nice in Telegram, but photos are shrunk by Telegram) or "as original file" (exact copy, shown as a file). Videos sent as media are also re-compressed by Telegram. Choose per rule.

---

## 4. The four tabs

### Home
Tells you, in one card, whether it is working and whether anything needs you: **Backing up**, **Paused**, **Waiting for Wi-Fi**, **Done for today**, **All backed up**, or a problem with one button to fix it (**Fix**, **Log in**, **Review**, **Continue setup**). Below it: today's uploaded count, how much space was freed, what is in the queue and what was skipped. Buttons: **Scan now**, **Upload now**, **Pause** / **Resume**.

### Rules
One card per rule: folder, topic, **Upload only** or **Upload & delete · N days**, and a switch to turn the rule off. Tap a rule to see its numbers, then **Edit** to change it. **Add a rule** makes a new one.

### History
Every upload, delete and problem, newest first, with filters **All, Uploaded, Deleted, Skipped, Problems**. Tap a file to see its details, its **check code**, and **Open in Telegram**. The **Find** box searches by name.

### Settings
See section 8.

---

## 5. Rules, one by one

Open **Rules**, tap a rule, then **Edit** (or **Add a rule**).

| Setting | What it does |
|---|---|
| **Name** | Shown in the app and used for the topic name. |
| **Folder** | The folder to watch. **Include folders inside it** also looks in its subfolders. |
| **File types** | Photos and videos, photos only, or videos only. |
| **Telegram topic** | Which topic receives the files. The app makes it when you create the rule. |
| **Send as** | **Media** (looks nice, photos made smaller by Telegram) or **Original file** (exact copy). |
| **Put photos of documents in the Documents topic** | On: pictures that look like paper, bills, letters and ID cards go to the Documents topic instead of this rule's topic. Off: everything stays in this rule's topic, exactly as it is. Videos are never checked. Choose the Documents topic once in Settings > Sending first. |
| **Back up from** | **Today on**, **Everything**, or **Since a date**. The line under it says how many files that adds right now. |
| **After upload** | **Keep on phone (upload only)**, or **Delete from phone after N days** (section 6). |
| **First delete needs your check** | On by default. The first time deleting would happen, the app shows you the files and waits for **Looks right, delete**. |

Turn a rule's switch off and nothing is scanned or uploaded for it. **Delete this rule** removes only the rule and its waiting queue: files on the phone and in Telegram are not touched.

---

## 6. Deleting from your phone

> **Short answer to "what does it delete?"** When you turn delete on for a rule, it covers files that are **already uploaded** *and* files uploaded **in the future**. Both follow the same clock, and both pass the same checks. Read on for exactly how.

### The clock
Every file gets a delete date: **the day Telegram's copy was checked, plus N days** (N is the number you choose on the rule, 1 to 365; the default is 7). The date is fixed per file at that moment.

When you turn delete on, or change N, the app recalculates the delete date of **every file the rule has already uploaded and checked**, using the day each was checked.

- A file checked 10 days ago with N = 7 is **already past its date**: it is due right away.
- A file checked yesterday with N = 7 is due in 6 days.
- A file uploaded after you turned delete on gets its date the moment its upload is checked.

So turning delete on **does** reach your existing backup, not only new files, but only files whose date has arrived. To free the space of the old files quickly, choose a small N (for example 1 day).

### How to turn it on (one rule at a time)
1. **Rules**, tap the rule, **Edit**.
2. Under **After upload** choose **Delete from phone after**, and type the number of days.
3. The warning **Delete from this phone?** appears. Read it, tick **I understand Telegram keeps the only copy**, tap **Turn on delete**. After this, Telegram is the only copy. If you lose the Telegram group or account, the files are gone.
4. Leave **First delete needs your check** ticked. Save.

Do this for each rule you want (for example both Gallery rules). It is per rule on purpose.

### What happens next
- The next time the daily job runs (overnight, or sooner if you press **Scan now** / **Upload now** and it reaches the clean-up stage), the app collects every file of that rule whose date has arrived. With the check switched on, it does **not** delete yet. Home shows a **Review** button and you get a notification: "<rule>: N files (size) are ready to delete from your phone."
- Tap **Review**. You see the count and total size, and you can tap photos to see them and their Telegram message.
- **Looks right, delete** approves. The listed files are deleted right then, and the rule stops asking for review from now on: later files are deleted automatically on their date. **Not now** leaves everything as it is, and the list stays waiting.
- Each run handles up to 500 files per rule; if more are due, the rest go in the next nightly run.

### The checks before each single file is deleted
The app deletes a file only if **all** of these are true at that moment. If any fails, the file is kept and History says why ("Delete waiting: ...").
1. It is marked uploaded **and checked**, with the Telegram message saved.
2. It was not sent in parts (big videos cut in parts are never deleted by the app).
3. The rule is set to delete and you accepted the warning.
4. The rule is switched on.
5. Deletes are not blocked for the whole app (for example, **All files access** was withdrawn).
6. Its delete date has arrived.
7. You approved the first-delete review (or the rule is past it).
8. The file on the phone is **exactly** the one that was uploaded (same size and same modified time). If you edited or replaced it since, it is not deleted.
9. Your Telegram account (logged in) **re-fetches the message from Telegram right now** and confirms it still exists, with the right size. If Telegram cannot be reached, or the message is missing or wrong, nothing is deleted.

Point 9 is why logging in to your account matters: **no login, no delete**.

### What it will not touch
- Files in folders that have no rule, and rules left on **Upload only**.
- Files that failed or were skipped (they were never confirmed in Telegram).
- Videos sent in parts.
- Anything while **Stop all deletes now** is active (see below).

### Taking it back
- **Settings > Safety > Stop all deletes now** makes every rule **Upload only** at once and cancels waiting reviews. Files already deleted stay deleted, so use it before the clean-up runs, not after.
- To pause deleting for one rule, edit it and choose **Keep on phone (upload only)**; its delete dates are removed. Choosing delete again recalculates them.

### Recommended order
1. Run with **Upload only** for about a week.
2. Open a few files in Telegram from different days and check they look right.
3. Turn delete on for **one** rule with a small number of files, approve its review, and look at your phone's Gallery.
4. Then turn it on for the others.

### Both Gallery rules at once
Turn on delete in the photos rule *and* the videos rule separately; each gets its own review. Photos that went to the Documents topic belong to the photos rule, so they are deleted by that rule's date as well. Remember the two videos that went up in parts are not deleted by the app: remove those two by hand in your Gallery after checking them in Telegram.

---

## 7. Finding and restoring your files

- **In Telegram**: open your group. Each rule has its own topic. Photos and videos taken on the same day sit together in one album. Documents are in the **Documents** topic.
- **Search**: every caption contains `#tb`. Search `#tb` plus the **check code** shown on the file's page in History (the first 12 characters of the file's fingerprint) to find a specific file.
- **From the app**: History > tap a file > **Open in Telegram**.
- **Getting a file back on your phone**: in Telegram open the message, tap and hold, **Save to Gallery** (or **Save to Downloads**). For files sent as **Media** the saved photo is Telegram's smaller version; files sent as **Original file** come back exactly as they were.

---

## 8. Settings

| Section | Item | Meaning |
|---|---|---|
| Network | **Use mobile data** | Off: uploads wait for Wi-Fi. |
| Pause buttons | **Delay options** | The "Delay 2h / 5h" buttons. 1 to 4 choices, 15 minutes to 24 hours. |
| New rules | **Keep on phone after upload** | The default number of days for new rules. |
| Sending | **Group each day's photos** | Albums of up to 10 per day. |
| Sending | **Documents topic** | Where document photos go. **Make a topic called Documents**, or pick an existing one, or **Turn off**. |
| Telegram | **Bot, group and account** | See the connection, change the bot or group, log in or out of the account. Changing the group sends new uploads to the new group and keeps old ones where they are. |
| Phone | **Permissions**, **Background running** | Shows what is allowed and fixes what is not. |
| Safety | **Stop all deletes now** | Every rule becomes upload only. |
| Rules | **Export rules** / **Import rules** | Saves or loads your rule list (not your files, not your keys). |
| Help | **Diagnostics** | A text report for whoever helps you. It contains no passwords, tokens or phone numbers. **Copy** or **Share** it. |
| Help | **Setup again** | Opens the setup steps again. |
| About | version | The version number, shown at the bottom of Settings. |

---

## 9. Updating, moving phones, uninstalling

**Updating.** Download the new APK from Releases and install it over the old one. Your rules, history and login stay. **Never uninstall first**: that erases the app's memory of what is already backed up, and the next scan would upload everything again and could never delete the old files. An update only installs over an older version if it was signed by the same key, which is why the key (`release.jks`) must be kept safe (docs/RELEASES.md).

**New phone.** Install the app, set it up again (bot token, group, login). In the old phone use **Settings > Export rules** and in the new one **Import rules** to bring your rule list. Imported rules start switched off and as upload only, for safety, and start from "Today" so old files are not uploaded twice. Your files are safe in Telegram regardless.

**Uninstalling.** Your files in Telegram are not affected. Telegram keeps them as long as the group and your account exist.

---

## 10. If something is wrong

Start at **Home**: each warning has one button that goes to the fix.

| What you see | What to do |
|---|---|
| **Setup not finished** | **Continue setup**. |
| Nothing uploads | Check Home for **Waiting for Wi-Fi** (connect, or **Use mobile data once**) or **Paused** (**Resume**). |
| Notification says Backing up for a long time | A big gallery takes hours. Open Home: if the numbers move, it is working. |
| "Permission" warning | **Fix**, then allow **All files access** and **Run in background** again. Android sometimes withdraws them after an update. |
| Backup stops after the phone restarts | Turn on your phone maker's **Auto-start** (Settings > Permissions, then **How** beside the Auto-start line). |
| "That token did not work" | Copy the bot token again from @BotFather (`/mybots`), or make a new bot with `/newbot`. |
| "No group found" | Make sure the bot is in the group, Topics is on, the bot is admin with **Manage topics**, and send a new message in the group. |
| **Log in** warning, "Your Telegram account was logged out" | Settings > Telegram > **Log in** again. Someone may have ended the session in Telegram's devices list. |
| Files show **Skipped** | Open the file in History to see why: too big and not cuttable, no free space for cutting, file changed, and so on. |
| A file says "Delete waiting: ..." | The app is waiting for one of the checks in section 6. The word after the colon names which one. |
| Telegram says "Too many requests" | The app slows down by itself and tries again. Nothing for you to do. |
| Still stuck | **Settings > Diagnostics > Share** the report with whoever set this up. |

---

## 11. Safety rules built into the app

- It never deletes a file unless Telegram has confirmed it, and for files sent through your account it re-checks with Telegram **immediately before** each delete.
- Deleting is off by default, is switched on per rule, needs you to accept a warning, and its first run waits for your review.
- Only one piece of code in the app can delete a phone file, and an automatic test fails the build if any other code tries.
- A file that changed after upload, a missing file, or a Telegram message that cannot be found is never deleted.
- Videos sent in parts are never deleted by the app.
- **Stop all deletes now** is always one tap away.

---

## 12. Privacy

- Your files go from your phone to your own Telegram group. There is no teleBackup server and nobody else can see them.
- Your bot token, app key and login session are kept in the phone's secure storage, never in a file you can copy and never sent anywhere except to Telegram.
- The document detector, the text reader and the picture labeller run entirely on the phone, offline.
- Diagnostics reports leave out tokens, passwords and phone numbers.
- The app has no ads, no analytics and no account of its own.

---

## 13. Known limits (honest list)

- The Telegram login uses a community build of Telegram's official library (TDLib 1.8.67). A build from Telegram's source is planned before this is given to other people.
- The document detector misses some ID cards held in a hand and sometimes flags signboards.
- Videos over 2 GB are cut only for mp4, m4v, mov and 3gp, and into at most 10 parts.
- The first real delete on a phone has not yet been watched in the Gallery app for leftover thumbnails. If an empty tile remains, open the Gallery and refresh it.
- Overnight behaviour with the screen off depends on the phone maker's battery rules; if backups stop at night, set the app to **Unrestricted** battery use.
- Android 11 or newer only. iPhone is not supported.
