# teleBackup: guide for family

*(Draft. It must be tested on one person who has not seen the app, with screenshots from the real phone, before it is handed out. See `docs/phases/M7.md` task 4.)*

teleBackup moves your photos and videos to your own private Telegram group so your phone has room again. Nothing goes to anyone else. Only you can see the group.

## Install
1. Someone sends you the file **teleBackup.apk** in Telegram.
2. Tap it. If the phone asks, allow "Install unknown apps" for Telegram (or Files). Tap **Install**.
3. Open **teleBackup**.

## Set up (about 10 minutes)
The app walks you through it, one step at a time. You need the Telegram app on the same phone.
1. **Permissions**: allow notifications, "All files access" and "Run in background". All three are needed.
2. **Make your bot**: in Telegram open @BotFather, send /newbot, pick a name, copy the token it gives you, paste it into teleBackup.
3. **Make your group**: new group in Telegram, turn on **Topics** in its settings, add your bot as an **admin** with "Manage topics", send one message. Then tap **Find my group**.
4. **Your account** (optional now): lets teleBackup send big videos and double-check before deleting. You can skip it and do it later.
5. **What to back up**: tick the folders. Leave "Today on" unless you want your old photos too.

## What you will see
- **A notification** while it uploads: "Backing up", with a **Pause** button. When paused you get **Delay 2h**, **Delay 5h** and **Resume**.
- It uploads on **Wi-Fi only**, unless you allow mobile data in Settings.
- **Home** says what is happening and has one button for every problem.

## Finding your photos in Telegram
Open your group. Each folder has its own **topic** (Gallery photos, Screenshots...). To find one file, search `#tb` and the check code shown on the file's page in teleBackup.

## Deleting from the phone (off until you turn it on)
Every rule starts as **Upload only**: nothing is deleted. After a week, if you want space back, open the rule and choose **Delete from phone after N days**. The app warns you that Telegram then holds the only copy. The first time, it shows you the files and waits for you to say **Looks right, delete**. **Settings > Stop all deletes now** turns every rule back to upload only at once.

## If something is wrong
Open **Home**. Each warning has a button. If the backup seems stuck, open **Settings > Diagnostics** and send the text to the person who set this up. It contains no passwords or tokens.

## Updating
You will be sent a new **teleBackup.apk**. Install it over the old one. Your rules and history stay. Never uninstall first: that erases the app's record of what is already backed up.
