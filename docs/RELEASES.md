# teleBackup releases

One entry per version: date, what changed, the APK's SHA-256. Every release bumps `version:` in `app/pubspec.yaml` (name+code, code always goes up) and `app/lib/ui/version.dart`.

| Version | Date | APK SHA-256 | Notes |
|---|---|---|---|
| 1.0.0 (2) | 2026-11-02 | `51b45a4a9c647275f72f5a3de308123e2bbb868abc70cb180683d9c0e93417b6` (`teleBackup-1.0.0-arm64.apk`, arm64-v8a, 68 MB) | First release. Signed with the family key (cert SHA-256 `1f8aebe4816881ac1eff6299481353754ce1bae89356d86c2c39eeecf857f1ac`), R8 on, not debuggable, no developer screen. Published as a GitHub Release. The Android versionCode is 2002 because `--split-per-abi` adds 2000 for arm64. Built after 241 Kotlin and 79 Flutter tests passed. **Not yet installed on a phone**: the owner's phone runs the debug-signed development build, which this release cannot replace without uninstalling it (see below). TDLib is still the community build. |
| 0.1.0 (1) | not released | `0437f6b6d1f037a73f6bc5223703512fe4f33db1ec8e24a348c6475b31cf8eeb` (arm64-v8a, built 2026-11-02) | An early test build. Never published. |

## The release key (made 2026-11-02)
- File: `C:\Users\aakas\.telebackup\release.jks` (PKCS12, alias `telebackup`, valid 25 years). Password: vault `parinama` / `TELEBACKUP_RELEASE_KEY_PASSWORD` (store and key use the same one). `app/android/key.properties` (git-ignored) points to it.
- **The owner must copy `release.jks` somewhere safe** (a USB stick, a private cloud folder) and keep the password. If both are lost, an installed app can never be updated, only replaced after uninstalling, which erases its record of what is backed up.

## How to make a release (once the key exists)
1. Put `app/android/key.properties` (git-ignored) pointing to the `.jks` outside the repo: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`.
2. Bump the version in `pubspec.yaml` and `lib/ui/version.dart`.
3. `cd app && flutter build apk --release --split-per-abi`; use `app-arm64-v8a-release.apk`.
4. `sha256sum` it, add the line here, send the file and the hash.
5. A release build without the key **fails on purpose**. `TELEBACKUP_DEBUG_SIGNED_RELEASE=1` makes a debug-signed build for checking only; never hand that out.

## Moving the owner's phone from the development build to the release
The development build on the owner's phone is signed with the computer's debug key, so Android refuses to install the family-signed release over it. The only way is to uninstall first, which erases the app's database: it would forget the 582 files already uploaded, so it could never delete them and a scan "Everything" would upload them again. Do this only after the old files have been dealt with (deleted through the app, or the owner accepts a fresh start with "Today on").
