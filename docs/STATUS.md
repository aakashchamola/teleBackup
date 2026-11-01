# teleBackup: where things stand (2026-11-02, updated after the phone arrived)

Everything that can be built and proven on a computer is built and tested. What is left needs **the owner's phone**, a **throwaway Telegram group**, or **the owner's decisions**. Nothing below is marked done unless a test or a build proved it.

## Proven on this computer
| What | How it is proven |
|---|---|
| Kotlin core: state machine, delete gate, router, pacer, captions, reply checks, redaction, scanner, upload loop, cleaner, reviews, kill switch, controls, rules, settings, status, export/import, diagnostics, folder catalog | **201 JVM tests**, 0 failing (`cd app/android && ./gradlew :app:testDebugUnitTest`) |
| Real SQLite through Room (every DAO query, enum storage, paging, the whole scan > upload > review > delete pipeline) | `RoomStoresTest`, 16 tests, via Robolectric |
| Bot API client against a fake Telegram server (request shape, every error row, token never logged, setup calls) | `BotApiTest` |
| "Only one door" rules: only `FileDeleter` can delete; only the state machine writes `state`; only the delete gate makes a delete permit | `SourceScanTest` + a 20,000-case random check of the gate |
| Flutter screens: setup O1-O7, Home with every status-card variant, rules list/detail/editor/folder/topic, delete warning, review, history, file detail, settings, Telegram connection, login, permissions, diagnostics, developer, navigation, notification routes, 320 dp wide at 200% text, dark theme | **74 widget tests** (`cd app && flutter test`), `flutter analyze` clean |
| Debug APK builds; release APK builds with code shrinking (R8) and **refuses to build without the family signing key** | `flutter build apk --debug`, `TELEBACKUP_DEBUG_SIGNED_RELEASE=1 flutter build apk --release --split-per-abi` |
| On the Moto G62 (Android 13): migration, real Keystore, MediaStore scan, file delete, TDLib starts and asks for a phone number | `:app:connectedDebugAndroidTest` (5 + 1 pass) |
| The whole bot path on the phone: scan, upload to a topic, reply check, review, delete through the gate | `BotEndToEndTest` (`am instrument`, token from the vault), passed twice |
| Bot API facts (photo shrinking, 50 MB edge, errors, byte-exact download) | `docs/M1_FINDINGS.md` |

## Not done, and why
| Item | Needs | Phase |
|---|---|---|
| Run the app on the phone, record the phone model | The phone plugged in with USB debugging (`adb devices` shows nothing now) | M0 |
| Every M1 question (Q1-Q7), `docs/M1_FINDINGS.md` | Phone + throwaway Telegram group with Topics + bot token (`tools/make_testkit.sh`, `tools/push_testkit.sh` are written, not yet run) | M1 |
| **Account login and a real send as the account** (the code is written and runs: `AccountAuth`, `AccountSender`, `AccountRecheck`, `TdlibGateway`; 11 + 3 JVM tests with a fake gateway) | **api_id and api_hash** from my.telegram.org (only the owner can get them), then the owner logs in once on the phone. After that: a 75 MB send, a 1 GB send with a Wi-Fi drop, and the bot-message re-fetch (Q6) are still to be run | M1/M3/M4 |
| TDLib binary: the one in use is a community build | Build it from tdlib/td before a family release (`docs/M1_FINDINGS.md` Q5) | M7 |
| D1: may a bot-only setup delete? | The owner. Default is **no** (`delete.allowBotOnly = false`), so with no account **nothing is ever deleted** | M1 |
| Device checks F1-F15, background survival for hours, Android 15 time limit, maker settings | Phone | M3/M6 |
| Family test of setup, TalkBack pass, screenshots | A person and the phone | M5 |
| 5,000-file backlog, rate-limit tuning, `perms/MakerGuide` wording per maker | Phone, time | M6 |
| Signing key, release 1.0.0, family roll-out | The owner makes and backs up the key (`docs/phases/M7.md` task 1) | M7 |

## Safety state
Every new rule starts upload-only and in dry-run. Delete needs the warning dialog, then a first review the person approves. `stopAllDeletes` exists. No code path deletes without the gate, and the gate refuses when the strong check is not available. **No real folder has ever been touched by this code**: nothing has run on a phone.

## Next steps, in order
1. Plug the phone in, turn on USB debugging, `adb devices` shows it. Run `flutter run -d <id>` from `app/`. (M0)
2. Make the throwaway Telegram group with Topics, a test bot, and run `tools/make_testkit.sh` then `tools/push_testkit.sh`. (M1 setup)
3. Walk the setup on the phone; then work through `docs/phases/M1.md` and fill `docs/M1_FINDINGS.md`.
4. Decide D1 and the TDLib source (A prebuilt / B build). Then add `AccountSender`, `AccountAuth`, `AccountVerifier` (M3/M4).
5. Device checks, then the week of upload-only on real folders, then Screenshots delete (ROADMAP test plan).

## Deviations from the design docs (found while building)
- **Rule names**: Room cannot express the "unique among live rules" index, so `RuleRepository` enforces it (checked in `RuleValidator`).
- **Flood-wait**: short waits (up to 2 minutes) are slept through inside the run; a long account flood-wait blocks only the account route, not bot uploads (M6 asked for this).
- **Queue query** also hides a `QUEUED` file whose `nextAttemptAt` is in the future (flood-wait).
- **Dev tools** (S-DEV, time warp, fault injection) are in the main source set but refuse to act unless the build is debuggable (`FLAG_DEBUGGABLE`). They are not compiled out of a release build; M7 asked for compile-out. Release APKs cannot reach them.
- **Rules export/import** use the share sheet and a paste box, not a file picker.
- **Suggested folders** travel over the bridge as `folder?types=photos|videos|both` because Gallery photos and videos share a folder.
- **Pigeon** classes use constructor-style fields (current Pigeon rejects `late` fields); calls are `suspend` on the Kotlin side.
- **`permission_handler` 12 and `dynamic_color` 1.x** are pinned: the newest versions need a newer Android toolchain / a different Material package than this Flutter ships.
- **Gradle download** on this PC: see `docs/SETUP.md` (Java's downloader times out, curl works).
