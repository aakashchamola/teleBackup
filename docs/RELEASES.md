# teleBackup releases

One entry per version: date, what changed, the APK's SHA-256. Every release bumps `version:` in `app/pubspec.yaml` (name+code, code always goes up) and `app/lib/ui/version.dart`.

| Version | Date | APK SHA-256 | Notes |
|---|---|---|---|
| 0.1.0 (1) | not released | | Built and tested on a computer only (see `docs/STATUS.md`). No signed APK exists: the release signing key is made by the owner (`docs/phases/M7.md` task 1). |

## How to make a release (once the key exists)
1. Put `app/android/key.properties` (git-ignored) pointing to the `.jks` outside the repo: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`.
2. Bump the version in `pubspec.yaml` and `lib/ui/version.dart`.
3. `cd app && flutter build apk --release --split-per-abi`; use `app-arm64-v8a-release.apk`.
4. `sha256sum` it, add the line here, send the file and the hash.
5. A release build without the key **fails on purpose**. `TELEBACKUP_DEBUG_SIGNED_RELEASE=1` makes a debug-signed build for checking only; never hand that out.
