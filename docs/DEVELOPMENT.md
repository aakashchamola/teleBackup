# teleBackup: development guide

How the code is laid out, which tools and libraries it uses, and how work is done. Read with `docs/ARCHITECTURE.md` (the design) and `docs/phases/` (what to build, in order).

## 1. Repo layout
```
teleBackup/
|- CLAUDE.md                 rules for every session
|- README.md
|- docs/
|  |- PLAN.md                product decisions (do not change without the owner)
|  |- ARCHITECTURE.md        design overview
|  |- HOW_IT_WORKS.md        end-to-end behaviour
|  |- UI.md                  every screen, dialog, notification, with copy
|  |- DATA_MODEL.md          database, states, delete gate
|  |- BRIDGE.md              Flutter <-> Kotlin contract
|  |- TELEGRAM.md            Bot API + TDLib details
|  |- TESTING.md             tests and device checks
|  |- DEVELOPMENT.md         this file
|  |- ROADMAP.md             milestones, risks
|  |- SETUP.md               installing tools, connecting the phone
|  |- M1_FINDINGS.md         answers found on the real phone (filled in M1)
|  |- SESSION_LOG.md         what was done, newest last
|  '- phases/M0.md ... M7.md step-by-step plan per milestone
|- app/                      the Flutter project (made in M0)
|  |- pubspec.yaml
|  |- pigeons/core_api.dart  bridge contract (M2)
|  |- lib/
|  |  |- main.dart           runApp, ProviderScope
|  |  |- app.dart            MaterialApp.router, theme, router
|  |  |- bridge/             generated API + wrappers + FakeCore
|  |  |- ui/
|  |  |  |- strings.dart     every user-visible string
|  |  |  |- theme.dart
|  |  |  |- format.dart      SizeText, TimeText helpers
|  |  |  '- widgets/         shared widgets (UI.md section 11)
|  |  '- features/
|  |     |- setup/           O1-O7
|  |     |- home/            S-HOME
|  |     |- rules/           S-RULES, S-RULE, S-EDIT, S-FOLDER, S-TOPIC, S-REVIEW
|  |     |- history/         S-HIST, S-FILE
|  |     |- settings/        S-SET, S-TG, S-LOGIN, S-PERM, S-DIAG
|  |     '- dev/             S-DEV (debug only)
|  |- test/                  Dart unit + widget tests (use FakeCore)
|  |- integration_test/      on-device Flutter tests (few)
|  '- android/
|     |- app/build.gradle.kts
|     |- app/schemas/        Room schema JSON (committed)
|     |- app/src/main/AndroidManifest.xml
|     |- app/src/main/kotlin/com/aakashchamola/telebackup/
|     |  |- MainActivity.kt
|     |  |- TeleBackupApp.kt          Application: WorkManager config, channels, ServiceLocator
|     |  |- bridge/                   CoreApi.g.kt (generated), CoreHostApiImpl.kt, CoreEventsBridge.kt
|     |  '- core/                     NO Flutter imports below here
|     |     |- di/ServiceLocator.kt   plain manual wiring (no DI framework)
|     |     |- db/                    AppDatabase, entities, DAOs, converters, migrations
|     |     |- model/                 enums, FileStateMachine, RuleValidator
|     |     |- settings/              SettingsRepository
|     |     |- rules/                 RuleRepository, FolderCatalog (suggested folders)
|     |     |- scan/                  Scanner, MediaSource (MediaStore + file fallback), ScanWorker
|     |     |- upload/                UploadWorker, UploadLoop, Router, Pacer, Hasher, CaptionBuilder
|     |     |- telegram/              TelegramSender, TgError, SendJob, SentMessage
|     |     |  |- bot/                BotApi (OkHttp), BotSender, BotSetup, dto/
|     |     |  '- account/            TdClient, AccountSender, AccountAuth, AccountVerifier, TdIds
|     |     |- verify/                Verifier (reply checks)
|     |     |- clean/                 CleanWorker, Cleaner, DeleteGate, FileDeleter, Reviews
|     |     |- control/               ControlState, ControlReceiver, ResumeWorker
|     |     |- notify/                Notifier, channels
|     |     |- status/                StatusHub, Attention
|     |     |- secrets/               SecretStore (Keystore AES-GCM)
|     |     |- perms/                 PermissionState, MakerGuide
|     |     |- log/                   Tlog (redacting logger), EventLog, Diagnostics
|     |     '- time/                  Clock interface (real + fake), TimeWarp
|     |- app/src/debug/kotlin/...     DevTools (S-DEV backend), fault injection
|     |- app/src/test/                JVM unit tests (fast, run on the computer)
|     '- app/src/androidTest/         instrumented tests (Room migrations, MediaStore, workers)
'- tools/
   |- make_testkit.sh        makes test photos/videos (M1)
   '- push_testkit.sh        copies them to the phone test folder with adb
```

## 2. Versions and targets
| Item | Value |
|---|---|
| Application id | `com.aakashchamola.telebackup` (`flutter create --org com.aakashchamola --project-name telebackup`) |
| App name | teleBackup |
| `minSdk` | 30 (Android 11). Needed for "All files access" as designed; older phones are out of scope. |
| `targetSdk` / `compileSdk` | The Flutter stable default at M0 (35 or newer). |
| Java | JDK 17 for Gradle. Kotlin JVM target 17. |
| ABIs | `arm64-v8a` always; `armeabi-v7a` only if a family phone needs it (TDLib size). |
| Flutter | Latest stable at M0. The exact version is written in SETUP.md and pinned in `pubspec.yaml` (`environment: flutter:`). |

## 3. Libraries
Kotlin (`app/android/gradle/libs.versions.toml`, latest stable at M2, then pinned):
| Library | For |
|---|---|
| `androidx.room` (+ KSP) | database |
| `androidx.work:work-runtime-ktx` | workers, foreground |
| `androidx.work:work-testing` | worker tests |
| `kotlinx-coroutines-android` | async |
| `kotlinx-serialization-json` | Bot API JSON, export file |
| `com.squareup.okhttp3:okhttp` + `mockwebserver` (test) | Bot API |
| TDLib (`org.drinkless.tdlib`, from M1) | account |
| `androidx.exifinterface` | taken date / size fallback |
| JUnit 4/5, Truth or AssertJ, Robolectric (where needed) | tests |

Dart (`pubspec.yaml`):
| Package | For |
|---|---|
| `flutter_riverpod` | state |
| `go_router` | navigation |
| `dynamic_color` | Material You colours |
| `pigeon` (dev) | bridge codegen |
| `permission_handler` | notification permission request only (others are custom intents in Kotlin) |
| `intl` | dates, sizes |
| `url_launcher` | open t.me links, BotFather, my.telegram.org |
| `flutter_test`, `integration_test` | tests |

Keep the list short. Adding a library needs a reason in the commit message.

## 4. Commands
From `app/`:
| Do | Command |
|---|---|
| Run on the phone | `flutter run -d <device-id>` (find the id with `flutter devices`) |
| Dart tests | `flutter test` |
| Format Dart | `dart format lib test` |
| Analyze Dart | `flutter analyze` |
| Bridge codegen | `dart run pigeon --input pigeons/core_api.dart` |
| Kotlin unit tests | `cd android && ./gradlew :app:testDebugUnitTest` |
| Instrumented tests (phone connected) | `cd android && ./gradlew :app:connectedDebugAndroidTest` |
| Debug APK | `flutter build apk --debug` |
| Release APK (M7) | `flutter build apk --release --split-per-abi` |
| Phone logs (core only) | `adb logcat -s TeleBackup:V` |
| WorkManager state | `adb shell dumpsys jobscheduler \| grep -A3 telebackup` |

## 5. Rules for the code
1. **The core stands alone.** Nothing under `core/` imports Flutter or `bridge/`. Workers construct what they need from `ServiceLocator`.
2. **One door for deletes.** Only `core/clean/FileDeleter.kt` may call `File.delete`, `contentResolver.delete`, `Files.delete`, or `MediaStore.createDeleteRequest`. Enforced by a test.
3. **One door for state.** File `state` changes only via `FileStateMachine.transition`. Enforced by DAO design (no `@Update` that sets `state` directly; a `@Query` setter is private to `FileRepository`).
4. **Time is injected.** Use `Clock` everywhere (`clock.now()`), never `System.currentTimeMillis()` in logic, so tests and time warp work.
5. **No secrets in logs.** Use `Tlog` (wraps `android.util.Log`, tag `TeleBackup`), which redacts bot tokens (`\d+:[A-Za-z0-9_-]{30,}`), `api_hash` (32 hex), phone numbers and codes. Never log request bodies or URLs that include the token. Covered by a test.
6. **Plain-word errors.** Every `TgError`/`AppError` has a `userMessage` from `strings`-like constants in the core (`core/log/Messages.kt`) that matches UI.md wording.
7. **Small files, plain names.** One class per file in `core/`. Names say what it is (`Pacer`, not `RateLimiterManagerImpl`).
8. **Dart**: screens are `ConsumerWidget`s; logic lives in providers/notifiers, not in widgets. Strings come from `ui/strings.dart`.
9. **No analytics, no crash reporters, no network calls except Telegram.**

## 6. Working method
- Work milestone by milestone, in order. Each `docs/phases/Mx.md` has numbered tasks; do them in order, tick them in that file as they are done (`- [x]`), and commit.
- Starting a session: read `CLAUDE.md`, the current phase file, and the end of `docs/SESSION_LOG.md`.
- Branching: `main` only (personal project). Small commits, one task or less each. Push after each finished task (the owner wants everything pushed).
- Commit messages: first line says what changed for the app in plain words ("Scanner queues WhatsApp images newest first"). No Claude co-author line (owner's standing rule).
- Before every commit: `git diff --cached` checked for secrets; `flutter analyze` and the fast tests pass.
- After each piece of work: a few lines in `docs/SESSION_LOG.md` (what, what was found, what's next).
- Things found on the phone that change the design: write them in `docs/M1_FINDINGS.md` (or the phase file) **and** fix the design doc they contradict in the same commit.
- Decisions that belong to the owner (anything in PLAN.md, anything that risks deleting files): ask, do not decide.

## 7. Definition of done (every task)
- It works on the owner's phone (not only an emulator), where the task touches the phone.
- Tests for it are written and pass.
- Docs updated if behaviour differs from them.
- No secrets in the diff. Committed, pushed, session log updated.
