# teleBackup releases

One entry per version: date, what changed, the APK's SHA-256. Every release bumps `version:` in `app/pubspec.yaml` (name+code, code always goes up) and `app/lib/ui/version.dart`.

| Version | Date | APK SHA-256 | Notes |
|---|---|---|---|
| 0.1.0 (1) | not released | `0437f6b6d1f037a73f6bc5223703512fe4f33db1ec8e24a348c6475b31cf8eeb` (arm64-v8a, built 2026-11-02) | Signed with the family key (cert SHA-256 `1f8aebe4816881ac1eff6299481353754ce1bae89356d86c2c39eeecf857f1ac`), R8 on, TDLib classes kept. A test build only: never run on a phone (it would replace the debug install), TDLib is a community build, and the key is not backed up yet. |

## The release key (made 2026-11-02)
- File: `C:\Users\aakas\.telebackup\release.jks` (PKCS12, alias `telebackup`, valid 25 years). Password: vault `parinama` / `TELEBACKUP_RELEASE_KEY_PASSWORD` (store and key use the same one). `app/android/key.properties` (git-ignored) points to it.
- **The owner must copy `release.jks` somewhere safe** (a USB stick, a private cloud folder) and keep the password. If both are lost, an installed app can never be updated, only replaced after uninstalling, which erases its record of what is backed up.

## How to make a release (once the key exists)
1. Put `app/android/key.properties` (git-ignored) pointing to the `.jks` outside the repo: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`.
2. Bump the version in `pubspec.yaml` and `lib/ui/version.dart`.
3. `cd app && flutter build apk --release --split-per-abi`; use `app-arm64-v8a-release.apk`.
4. `sha256sum` it, add the line here, send the file and the hash.
5. A release build without the key **fails on purpose**. `TELEBACKUP_DEBUG_SIGNED_RELEASE=1` makes a debug-signed build for checking only; never hand that out.
