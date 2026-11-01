# teleBackup: setting up a computer and the phone

Where to develop: the **owner's own computer**. The shared work machine used for planning (adb + Java 11 only, disk 96% full) is not used for teleBackup builds; the owner decided on 2026-11-01 not to install the toolchain there.

The full step-by-step install with checkboxes is `docs/phases/M0.md`. This file is the short version. After M0, write here: pinned Flutter version, Android SDK platform, JDK, and the owner's phone (model, Android version).

- Pinned Flutter: _(fill in M0)_
- Android SDK platform / build-tools: _(fill in M0)_
- JDK: _(fill in M0)_
- Owner's phone: _(fill in M0)_
- Connection: USB cable (owner's choice).

## Computer (Linux or WSL 2)
1. Flutter SDK (stable) in `~/flutter`, on `PATH`.
2. Android command-line tools + platform-tools + one recent platform and build-tools; accept licences. Java 17 is needed by current Android builds (Java 11 here is too old for new Gradle), so install a JDK 17.
3. `flutter doctor` must show Android toolchain with no red marks.
4. At least 15 GB free disk. Building TDLib from source (only if M1 needs it) takes more; see `docs/TELEGRAM.md` section 3.

## Phone (debug mode)
1. Settings, About phone, tap **Build number** 7 times to unlock Developer options.
2. Developer options: turn on **USB debugging**.
3. Connect by cable, accept the "Allow USB debugging" prompt on the phone.
4. On the computer: `adb devices` should list the phone as `device`.
5. Wireless option (Android 11+): Developer options, **Wireless debugging**, pair with `adb pair`, then `adb connect`.
6. Run the app: `flutter run` from the app folder, or `flutter run -d <device id>`.

If the computer is WSL 2, `adb` inside WSL cannot see USB devices by default. Either run the Windows `adb.exe` and connect over wireless debugging, or attach the phone with `usbipd`.

## Telegram test kit (throwaway, not the real folders)
1. Create a Telegram **group**, turn on **Topics** in the group settings.
2. In BotFather create a bot, copy the token (kept only on the phone, never in this repo).
3. Add the bot to the group as admin: post messages, manage topics.
4. From my.telegram.org create an app to get `api_id` and `api_hash` (account path, M1).
5. Put a few test photos and videos in a folder like `Pictures/teleBackupTest`.

## Secrets
Entered in the app on the phone, stored with the Android Keystore. They do not go in files, chats or git.
