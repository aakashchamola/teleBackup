# Installing teleBackup on a family iPhone with SideStore (free, no Apple Developer account)

SideStore signs the app with a free Apple ID and then refreshes the signature **on the phone itself** (no computer needed after setup), so the 7-day limit does not stop the app. Steps are from docs.sidestore.io (checked 2026-11-03); do the setup once per phone, with the phone in your hands.

## Before you start
- iPhone with a passcode, iOS 15 or later (iPhone 15 and the mini are fine).
- A Mac or Windows PC for the first install only. Wi-Fi.
- An Apple ID for the phone. Use a free Apple ID; it does not have to be the person's main one (make a spare one if you prefer). Write down its password: SideStore asks for it.
- The file `teleBackup-ios.ipa` (made by `tools/build_ios_ipa.sh`, in `app/build/ios-release/`). Put it on the phone with AirDrop or iCloud Drive / Files.
- Free Apple ID limits: 3 apps at once (SideStore + teleBackup = 2, leave room for nothing else big), 10 new apps a week.

## Step 1: on the phone
1. Install **LocalDevVPN** from the App Store (or the AltStore PAL source).
2. Open it and tap **Connect** (allow the VPN configuration with the passcode). SideStore's docs say this VPN must be on any time you install, update or refresh apps. It only talks to the phone itself.

## Step 2: on the computer
1. Install **iloader** (iloader DMG on a Mac; on Windows install iTunes from Apple or the Microsoft Store first, then the iloader MSI).
2. Plug the phone in with a cable, unlock it, tap **Trust** and enter the passcode.
3. Open iloader, sign in with the Apple ID, pick the phone, and choose **Install SideStore (Stable)**.

## Step 3: on the phone
1. Settings > General > VPN & Device Management > under Developer App, tap the Apple ID > **Trust**.
2. Settings > Privacy & Security > scroll to the bottom > **Developer Mode** on (the phone restarts).
3. Open LocalDevVPN > **Connect**. Open **SideStore** and sign in with the same Apple ID.
4. In SideStore: **My Apps** > tap the "7 DAYS" counter next to SideStore to refresh it once. Accept "Refresh Now" if it asks about a certificate.

## Step 4: install teleBackup
1. In SideStore, tap **+** (top left) and choose `teleBackup-ios.ipa` from Files.
2. When it finishes, open teleBackup and do the normal setup (permissions, bot, group, rules).
3. In SideStore > **My Apps**, both SideStore and teleBackup should show about 7 days.

## Keeping it alive without anyone doing anything
- SideStore refreshes the apps in the background before they expire. Leave **Background App Refresh** on for SideStore, and keep LocalDevVPN installed.
- teleBackup warns on its Home screen and sends a notification 2 days before its signature runs out. If it ever appears: open LocalDevVPN > Connect, open SideStore > My Apps > refresh. That is the only upkeep.
- Not verified by me: how often and how reliably SideStore's background refresh runs on a real phone (the SideStore docs do not say how often). Check after the first week: open SideStore > My Apps and read the days left for teleBackup.

## If something goes wrong
- "Pairing file" problems after an iOS update or reset: follow docs.sidestore.io/docs/advanced/pairing-file.
- The app will not open ("Unable to Verify"/crashes at start): its signature ran out. Connect LocalDevVPN, open SideStore, refresh teleBackup. Nothing is lost: the queue is kept in the app.
