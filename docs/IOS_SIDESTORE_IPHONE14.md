# Installing SideStore on iPhone 14 / iPhone 15 (iOS 17+)

This guide walks through setting up **SideStore** on an iPhone 14 or iPhone 15 running iOS 17 or later. Once complete, **teleBackup refreshes its 7-day signature on the iPhone itself** over Wi-Fi without needing a Mac or computer ever again.

---

## Prerequisites

1. **iPhone 14 / 15** with a passcode and Wi-Fi.
2. **Mac or Windows PC** (needed only once for the initial setup; can be disconnected permanently afterwards).
3. **USB cable** to connect the iPhone to the computer.
4. **Free Apple ID** (use your primary Apple ID or create a free spare on [appleid.apple.com](https://appleid.apple.com)).

---

## Step 1: On the iPhone (LocalDevVPN & Developer Mode)

1. Open the App Store and install **LocalDevVPN**.
2. Open **LocalDevVPN** and tap **Connect** (allow the VPN configuration with your passcode).
   - *Note:* This is a loopback VPN that communicates only with the phone itself (127.0.0.1). It is required anytime you install or refresh apps in SideStore.
3. Enable Developer Mode:
   - Go to **Settings > Privacy & Security**.
   - Scroll to the bottom, tap **Developer Mode**, and turn it **ON**.
   - Tap **Restart** when prompted, and unlock with your passcode after reboot.

---

## Step 2: On the Computer (iloader)

1. Install **iloader**:
   - macOS: `brew install --cask iloader` or download the DMG from [iloader.app](https://iloader.app).
2. Plug your iPhone into the computer with a **USB cable** (do not use Wi-Fi for this step).
   - Unlock the iPhone and tap **Trust This Computer**.
3. Open **iloader**:
   - Sign in with your Apple ID. *(Must be the primary password, not an app-specific password).*
   - Under `iDevice`, select your iPhone.
   - Under `Installers`, click **SideStore (Nightly)** or **SideStore (Stable)**.
4. Wait for the notification that SideStore is installed on the phone.

---

## Step 3: On the iPhone (Trust the Developer)

1. Open **Settings > General > VPN & Device Management**.
2. Under `Developer App`, tap your Apple ID and tap **Trust**.

---

## Step 4: Fix Pairing File Ambiguity (iOS 17+ Requirement)

On iOS 17+, SideStore requires a Remote Pairing file (`RPPairing`). When exported from iloader, the file can contain combined credentials that trigger the error:
> *"The pairing file format is ambiguous: The pairing file contains credentials for both Remote Pairing and Lockdown protocols."*

### How to resolve:
1. In `iloader` on the Mac, scroll down to **Management** and click **Export (Not Recommended)** to save `pairingFile.plist`.
2. Run the helper script in the repository to clean the file:
   ```bash
   python3 tools/fix_pairing_file.py ~/Downloads/pairingFile.plist
   ```
   *(This outputs `PairingFile_RemoteRP.plist` in your Downloads folder).*
3. **AirDrop** `PairingFile_RemoteRP.plist` to the iPhone and save it to **Files**.
4. In SideStore, tap **Select Pairing File** and choose `PairingFile_RemoteRP.plist`.

---

## Step 5: Fix Anisette Error -80045 & Sign In

If SideStore shows:
> *"Failed to Sign In: This action cannot be completed at this time (-80045)"*

This happens because on-device ADI emulation is blocked by iOS 17's sandbox. Fix it with these settings:

1. In SideStore, go to **Settings > User Customizations**:
   - Turn **`On-Device Anisette` OFF**.
   - Tap **`Reset adi.pb`** (red text with trash icon) to clear old cache.
2. In SideStore **Settings**, scroll to **Anisette Servers**:
   - Select **SideStore (New)** (`https://new.ani.sidestore.io`).
   - Turn **OFF** *"Enable Auto Rotation"*.
3. Verify that **LocalDevVPN is Connected** (green checkmark).
4. Force-close SideStore and reopen it.
5. Go to **My Apps** and tap **Sign In** with your Apple ID.

---

## Step 6: Install teleBackup into SideStore

1. Transfer `teleBackup-ios.ipa` to the iPhone (via AirDrop, iCloud Drive, or Files).
2. Open **SideStore**, navigate to **My Apps**.
3. Tap the **`+`** icon in the top-left corner.
4. Select `teleBackup-ios.ipa` from Files.
5. SideStore will install and sign `teleBackup`. Both SideStore and teleBackup will now show **7 DAYS** remaining.

---

## How It Refreshes (Completely Computer-Free)

- **Automatic background refresh**: Leave **Background App Refresh** enabled for SideStore and keep LocalDevVPN installed. SideStore will automatically renew the signature in the background over Wi-Fi.
- **Manual refresh**: If you ever see teleBackup's 2-day expiry alert, simply open **LocalDevVPN** (Connect), open **SideStore**, go to **My Apps**, and tap the refresh button next to teleBackup.
- **You do NOT need the Mac or Xcode anymore.** You can safely delete Xcode from your Mac to free up disk space.

