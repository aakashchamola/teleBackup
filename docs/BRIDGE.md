# teleBackup: Flutter <-> Kotlin bridge

The UI (Flutter) and the core (Kotlin) talk only through this contract. It is written with **Pigeon** (typed code generation for platform channels), so both sides get matching classes and a wrong field is a compile error, not a runtime crash.

- Source of truth: `app/pigeons/core_api.dart` (made in M2 from this document).
- Generate: `cd app && dart run pigeon --input pigeons/core_api.dart`.
- Output: `app/lib/bridge/core_api.g.dart` and `app/android/app/src/main/kotlin/com/aakashchamola/telebackup/bridge/CoreApi.g.kt`. Generated files are committed.
- Kotlin implements `CoreHostApi` in `bridge/CoreHostApiImpl.kt`, which only calls into `core/` classes. **`core/` never imports anything from `bridge/` or Flutter**, so the background workers run with no Flutter engine at all.
- Dart wraps the generated API in `lib/bridge/core.dart` (a Riverpod provider) so screens never touch generated code directly, and tests swap in `FakeCore`.

## Rules for the contract
- Everything is async. Long work (scan, upload) is *started* by a call and *reported* by events; calls never wait for it.
- Errors: the Kotlin side throws `FlutterError(code, message)` with `code` from `BridgeErrorCode` below. `message` is plain words, safe to show.
- Times are epoch ms (`int`), sizes bytes (`int`), enums are Pigeon enums mirroring the Kotlin ones (`docs/DATA_MODEL.md`).
- Secrets go **in** only (token, api_hash, codes, password). No call ever returns a secret.
- Add fields at the end; do not reuse removed names. The app ships as one APK, so both sides always match, but this keeps diffs readable.

> **Built form (2026-11-02):** `app/pigeons/core_api.dart` is the source of truth. Current Pigeon needs constructor-style classes (`late` fields no longer work), so the snippet below shows the shape, not the exact syntax. Additions: `AppSettings.debugBuild`, `devCommand` (debug builds only), `CoreEventsApi.onOpenRoute`, `Review.id == 0` for a preview. Suggested folders travel as `folder?types=photos|videos|both`. Kotlin calls are `suspend`.

## The contract (Pigeon file)
```dart
// app/pigeons/core_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/bridge/core_api.g.dart',
  kotlinOut: 'android/app/src/main/kotlin/com/aakashchamola/telebackup/bridge/CoreApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.aakashchamola.telebackup.bridge'),
))

// ---------- enums (mirror docs/DATA_MODEL.md) ----------
enum MediaTypes { photos, videos, both }
enum UploadAs { media, original }
enum RuleMode { uploadOnly, uploadAndDelete }
enum StartMode { today, sinceDate, everything }
enum FileState { queued, uploading, uploaded, verified, deleted, failed, skipped, ignored, gone, changed }
enum ControlState { running, paused, delayed }
enum RunState { idle, scanning, uploading, pausing, waitingNetwork, stoppedTimeLimit, cleaning }
enum AccountState { none, waitParams, waitPhone, waitCode, waitPassword, waitOther, ready, expired }
enum AttentionKind { loginExpired, bigFilesWaitAccount, allFilesLost, notificationsOff, batteryOptimized,
                     botProblem, topicMissing, reviewWaiting, skippedRecently, setupNotDone }
enum HistoryFilter { all, uploaded, deleted, skipped, problems }

// ---------- status ----------
class Attention {
  late AttentionKind kind;
  late String text;          // ready to show
  int? ruleId;               // for topicMissing / reviewWaiting
  int? count;
}

class Status {
  late ControlState control;
  int? delayedUntil;
  late RunState run;
  String? currentFileName;
  int? currentFileBytesDone;
  int? currentFileBytesTotal;
  late int runFilesDone;      // this run
  late int runFilesTotal;
  late int queuedCount;       // QUEUED + due FAILED
  late int queuedBytes;
  late int waitingAccountCount;
  late int todayUploaded;
  late int todayFreedBytes;
  late int todaySkipped;
  late int freedBytesTotal;
  int? lastScanAt;
  int? lastUploadAt;
  String? lastStopReason;
  late List<Attention> attention;
  late bool onUnmeteredNetwork;
}

// ---------- rules ----------
class Rule {
  int? id;                    // null when new
  late String name;
  late String folderPath;
  late bool includeSubfolders;
  late MediaTypes mediaTypes;
  int? topicId;               // null = General
  String? newTopicName;       // set to create a topic on save
  late UploadAs uploadAs;
  late RuleMode mode;
  late int retentionDays;
  late StartMode startMode;
  int? startDate;
  late bool enabled;
  late bool dryRun;
  late bool deleteWarningAccepted;
}

class RuleStats {
  late int ruleId;
  late int queued;
  late int backedUp;          // VERIFIED
  late int backedUpBytes;
  late int waitingDelete;     // VERIFIED and deleteAfter <= now
  late int deleted;
  late int freedBytes;
  late int skipped;
  String? deleteBlockedReason;
  late bool topicMissing;
}

class RuleWithStats { late Rule rule; late RuleStats stats; }

class BacklogPreview { late int count; late int bytes; int? newestAt; int? oldestAt; }

class FolderInfo { late String path; late String label; late int mediaCount; String? usedByRule; late bool isSuggestion; String? hint; }

class Topic { late int threadId; late String name; late bool missing; late bool madeByApp; }

// ---------- files and history ----------
class FileItem {
  late int id;
  late int ruleId;
  late String ruleName;
  late String displayName;
  late String path;
  late int sizeBytes;
  late FileState state;
  int? takenAt;
  int? width; int? height; int? durationMs;
  String? sendAs;             // PHOTO/VIDEO/DOCUMENT
  String? shortHash;
  String? telegramLink;
  int? queuedAt; int? uploadedAt; int? verifiedAt; int? deleteAfter; int? deletedAt;
  String? lastError;
  late int attempts;
}

class EventItem { late int id; late int at; late String kind; late String message; int? fileId; int? ruleId; int? bytes; }

// Pigeon has no generics, so each paged list has its own class.
class EventPage { late List<EventItem> items; int? nextCursor; }
class FilePage { late List<FileItem> items; int? nextCursor; }

class Review { late int id; late int ruleId; late String ruleName; late int fileCount; late int totalBytes; late List<FileItem> files; late bool preview; }

// ---------- settings ----------
class AppSettings {
  late bool allowMobileData;
  late List<int> delayOptionsMinutes;
  late int defaultRetentionDays;
  late bool setupDone;
  late String setupStep;
}

// ---------- telegram setup ----------
class BotInfo { late int id; late String username; late String name; }
class GroupCandidate { late int chatId; late String title; }
class GroupCheck { late int chatId; late String title; late bool topicsOn; late bool botIsAdmin; late bool botCanManageTopics; }
class TelegramState {
  BotInfo? bot;
  GroupCheck? group;
  late AccountState account;
  String? accountName;
  String? accountPhoneMasked;
  String? codeSentTo;         // "Telegram app", "SMS"
  String? passwordHint;
  String? lastError;          // plain words
}

class Permissions { late bool notifications; late bool allFiles; late bool batteryExempt; late bool mediaRead; String? makerGuide; }

// ---------- host API: Flutter calls Kotlin ----------
@HostApi()
abstract class CoreHostApi {
  // status and controls
  @async Status getStatus();
  @async void pause();
  @async void resume();
  @async void delay(int minutes);
  @async void scanNow(int? ruleId);
  @async void uploadNow(bool mobileDataOnce);

  // rules
  @async List<RuleWithStats> listRules();
  @async RuleWithStats getRule(int id);
  @async int saveRule(Rule rule);            // validates, creates topic if newTopicName, triggers scan
  @async void setRuleEnabled(int id, bool enabled);
  @async void deleteRule(int id);
  @async BacklogPreview previewRule(Rule rule);
  @async List<FolderInfo> suggestedFolders();
  @async List<FolderInfo> listFolder(String path);
  @async List<Topic> listTopics();
  @async Topic remakeTopic(int ruleId);
  @async void stopAllDeletes();               // kill switch

  // reviews
  @async Review? getReview(int ruleId);       // the waiting one, or null
  @async Review previewDeletes(int ruleId);   // what would be deleted now (no side effects)
  @async void approveReview(int reviewId);
  @async void dismissReview(int reviewId);

  // files and history
  @async EventPage listEvents(HistoryFilter filter, String? search, int? ruleId, int? cursor);
  @async FilePage listFiles(int ruleId, FileState? state, int? cursor);
  @async FileItem getFile(int id);
  @async void retryFile(int id);

  // settings
  @async AppSettings getSettings();
  @async void setAllowMobileData(bool on);
  @async void setDelayOptions(List<int> minutes);
  @async void setDefaultRetention(int days);
  @async void setSetupStep(String step);
  @async void finishSetup();
  @async String exportRules();                // JSON text
  @async int importRules(String json);        // returns count

  // telegram
  @async BotInfo setBotToken(String token);   // checks with getMe, stores in SecretStore
  @async List<GroupCandidate> findGroups();
  @async GroupCheck checkGroup(int chatId);
  @async void selectGroup(int chatId);        // saves + posts hello message
  @async TelegramState getTelegramState();
  @async void accountStart(int apiId, String apiHash);
  @async void accountPhone(String phone);
  @async void accountCode(String code);
  @async void accountPassword(String password);
  @async void accountResendCode();
  @async void accountLogout();
  @async int createSuggestedRules(List<String> suggestionPaths, StartMode startMode, int? startDate);

  // phone
  @async Permissions getPermissions();
  @async void openAllFilesSettings();
  @async void requestBatteryExemption();
  @async void openNotificationSettings();

  // help
  @async String diagnostics();                // redacted text
}

// ---------- Flutter API: Kotlin calls Flutter (only while the UI is alive) ----------
@FlutterApi()
abstract class CoreEventsApi {
  void onStatus(Status status);               // at most 2 per second
  void onTelegramState(TelegramState state);  // login steps
  void onRulesChanged();                      // UI reloads the list
  void onHistoryChanged();
}
```

## Error codes (`FlutterError.code`)
| Code | When |
|---|---|
| `VALIDATION` | Bad input (rule name used, no folder). `message` names the field. `details` = field id. |
| `NOT_SET_UP` | Telegram not connected yet. |
| `NO_NETWORK` | A setup call needs the internet. |
| `TELEGRAM` | Telegram said no (wrong token, wrong code). `message` is plain words. |
| `FLOOD_WAIT` | Too many tries. `details` = seconds. |
| `PERMISSION` | Missing All files access etc. |
| `INTERNAL` | Anything else. Logged with a stack trace in the core log (never sent to the UI). |

## How events reach the UI
- `CoreEventsBridge` (Kotlin) holds a reference to `CoreEventsApi` while `MainActivity` has an engine. Core classes publish to a `StateFlow<Status>` in `core/status/StatusHub.kt`; the bridge collects it and forwards (throttled to 2/s).
- When the UI is closed, nothing is forwarded; the notification is the UI.
- On app resume, the UI calls `getStatus()` once anyway, so a missed event is never a problem.

## Dart side shape
```
lib/bridge/core_api.g.dart        generated
lib/bridge/core.dart              CoreRepository: wraps CoreHostApi, maps FlutterError -> AppError
lib/bridge/events.dart            implements CoreEventsApi, exposes Streams
lib/bridge/fake_core.dart         in-memory fake for widget tests and for running the UI without a phone
```
Providers (Riverpod): `statusProvider` (StreamProvider from events, seeded by `getStatus`), `rulesProvider`, `settingsProvider`, `telegramStateProvider`, `permissionsProvider` (refreshed on app resume).
