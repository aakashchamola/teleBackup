// The contract between the Flutter screens and the Kotlin core (docs/BRIDGE.md).
// Generate with:  dart run pigeon --input pigeons/core_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/bridge/core_api.g.dart',
  kotlinOut: 'android/app/src/main/kotlin/com/aakashchamola/telebackup/bridge/CoreApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.aakashchamola.telebackup.bridge'),
  swiftOut: 'ios/Runner/Bridge/CoreApi.g.swift',
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

enum AttentionKind {
  loginExpired,
  bigFilesWaitAccount,
  allFilesLost,
  notificationsOff,
  batteryOptimized,
  botProblem,
  topicMissing,
  reviewWaiting,
  skippedRecently,
  setupNotDone,
}

enum HistoryFilter { all, uploaded, deleted, skipped, problems }

// ---------- status ----------
class Attention {
  Attention({required this.kind, required this.text, this.ruleId, this.count});
  AttentionKind kind;
  String text;
  int? ruleId;
  int? count;
}

class Status {
  Status({
    required this.control,
    this.delayedUntil,
    required this.run,
    this.currentFileName,
    this.currentFileBytesDone,
    this.currentFileBytesTotal,
    required this.runFilesDone,
    required this.runFilesTotal,
    required this.queuedCount,
    required this.queuedBytes,
    required this.waitingAccountCount,
    required this.todayUploaded,
    required this.todayFreedBytes,
    required this.todaySkipped,
    required this.freedBytesTotal,
    this.lastScanAt,
    this.lastUploadAt,
    this.lastStopReason,
    required this.attention,
    required this.onUnmeteredNetwork,
  });
  ControlState control;
  int? delayedUntil;
  RunState run;
  String? currentFileName;
  int? currentFileBytesDone;
  int? currentFileBytesTotal;
  int runFilesDone;
  int runFilesTotal;
  int queuedCount;
  int queuedBytes;
  int waitingAccountCount;
  int todayUploaded;
  int todayFreedBytes;
  int todaySkipped;
  int freedBytesTotal;
  int? lastScanAt;
  int? lastUploadAt;
  String? lastStopReason;
  List<Attention> attention;
  bool onUnmeteredNetwork;
}

// ---------- rules ----------
class Rule {
  Rule({
    this.id,
    required this.name,
    required this.folderPath,
    required this.includeSubfolders,
    required this.mediaTypes,
    this.topicId,
    this.newTopicName,
    required this.uploadAs,
    required this.mode,
    required this.retentionDays,
    required this.startMode,
    this.startDate,
    required this.enabled,
    required this.dryRun,
    required this.deleteWarningAccepted,
    this.sortDocuments = false,
  });
  int? id; // null when new
  String name;
  String folderPath;
  bool includeSubfolders;
  MediaTypes mediaTypes;
  int? topicId; // null = General
  String? newTopicName; // set to create a topic on save
  UploadAs uploadAs;
  RuleMode mode;
  int retentionDays;
  StartMode startMode;
  int? startDate;
  bool enabled;
  bool dryRun;
  bool deleteWarningAccepted;
  bool sortDocuments; // photos of documents and paper go to the Documents topic (needs one chosen in Settings)
}

class RuleStats {
  RuleStats({
    required this.ruleId,
    required this.queued,
    required this.backedUp,
    required this.backedUpBytes,
    required this.waitingDelete,
    required this.deleted,
    required this.freedBytes,
    required this.skipped,
    this.deleteBlockedReason,
    required this.topicMissing,
  });
  int ruleId;
  int queued;
  int backedUp; // VERIFIED
  int backedUpBytes;
  int waitingDelete; // VERIFIED and deleteAfter <= now
  int deleted;
  int freedBytes;
  int skipped;
  String? deleteBlockedReason;
  bool topicMissing;
}

class RuleWithStats {
  RuleWithStats({required this.rule, required this.stats});
  Rule rule;
  RuleStats stats;
}

class BacklogPreview {
  BacklogPreview({required this.count, required this.bytes, this.newestAt, this.oldestAt});
  int count;
  int bytes;
  int? newestAt;
  int? oldestAt;
}

class FolderInfo {
  FolderInfo({required this.path, required this.label, required this.mediaCount, this.usedByRule, required this.isSuggestion, this.hint});
  String path;
  String label;
  int mediaCount;
  String? usedByRule;
  bool isSuggestion;
  String? hint;
}

class Topic {
  Topic({required this.threadId, required this.name, required this.missing, required this.madeByApp});
  int threadId;
  String name;
  bool missing;
  bool madeByApp;
}

// ---------- files and history ----------
class FileItem {
  FileItem({
    required this.id,
    required this.ruleId,
    required this.ruleName,
    required this.displayName,
    required this.path,
    required this.sizeBytes,
    required this.state,
    this.takenAt,
    this.width,
    this.height,
    this.durationMs,
    this.sendAs,
    this.shortHash,
    this.telegramLink,
    this.queuedAt,
    this.uploadedAt,
    this.verifiedAt,
    this.deleteAfter,
    this.deletedAt,
    this.lastError,
    required this.attempts,
  });
  int id;
  int ruleId;
  String ruleName;
  String displayName;
  String path;
  int sizeBytes;
  FileState state;
  int? takenAt;
  int? width;
  int? height;
  int? durationMs;
  String? sendAs; // PHOTO / VIDEO / DOCUMENT
  String? shortHash;
  String? telegramLink;
  int? queuedAt;
  int? uploadedAt;
  int? verifiedAt;
  int? deleteAfter;
  int? deletedAt;
  String? lastError;
  int attempts;
}

class EventItem {
  EventItem({required this.id, required this.at, required this.kind, required this.message, this.fileId, this.ruleId, this.bytes});
  int id;
  int at;
  String kind;
  String message;
  int? fileId;
  int? ruleId;
  int? bytes;
}

// Pigeon has no generics, so each paged list has its own class.
class EventPage {
  EventPage({required this.items, this.nextCursor});
  List<EventItem> items;
  int? nextCursor;
}

class FilePage {
  FilePage({required this.items, this.nextCursor});
  List<FileItem> items;
  int? nextCursor;
}

class Review {
  Review({required this.id, required this.ruleId, required this.ruleName, required this.fileCount, required this.totalBytes, required this.files, required this.preview});
  int id; // 0 for a preview with no waiting review
  int ruleId;
  String ruleName;
  int fileCount;
  int totalBytes;
  List<FileItem> files;
  bool preview;
}

// ---------- settings ----------
class AppSettings {
  AppSettings({required this.allowMobileData, required this.delayOptionsMinutes, required this.defaultRetentionDays, required this.setupDone, required this.setupStep, required this.debugBuild, this.groupByDay = true, this.documentsTopicId});
  bool groupByDay; // a day's photos and videos go together as albums
  int? documentsTopicId; // topic for sorted-out documents; null = none chosen
  bool allowMobileData;
  List<int> delayOptionsMinutes;
  int defaultRetentionDays;
  bool setupDone;
  String setupStep;
  bool debugBuild;
}

// ---------- telegram setup ----------
class BotInfo {
  BotInfo({required this.id, required this.username, required this.name});
  int id;
  String username;
  String name;
}

class GroupCandidate {
  GroupCandidate({required this.chatId, required this.title});
  int chatId;
  String title;
}

class GroupCheck {
  GroupCheck({required this.chatId, required this.title, required this.topicsOn, required this.botIsAdmin, required this.botCanManageTopics});
  int chatId;
  String title;
  bool topicsOn;
  bool botIsAdmin;
  bool botCanManageTopics;
}

class TelegramState {
  TelegramState({this.bot, this.group, required this.account, this.accountName, this.accountPhoneMasked, this.codeSentTo, this.passwordHint, this.lastError});
  BotInfo? bot;
  GroupCheck? group;
  AccountState account;
  String? accountName;
  String? accountPhoneMasked;
  String? codeSentTo; // "Telegram app", "SMS"
  String? passwordHint;
  String? lastError; // plain words
}

class Permissions {
  Permissions({required this.notifications, required this.allFiles, required this.batteryExempt, required this.mediaRead, this.makerGuide});
  bool notifications;
  bool allFiles;
  bool batteryExempt;
  bool mediaRead;
  String? makerGuide;
}

// ---------- host API: Flutter calls Kotlin ----------
@HostApi()
abstract class CoreHostApi {
  // status and controls
  @async
  Status getStatus();
  @async
  void pause();
  @async
  void resume();
  @async
  void delay(int minutes);
  @async
  void scanNow(int? ruleId);
  @async
  void uploadNow(bool mobileDataOnce);

  // rules
  @async
  List<RuleWithStats> listRules();
  @async
  RuleWithStats getRule(int id);
  @async
  int saveRule(Rule rule); // validates, creates topic if newTopicName, triggers scan
  @async
  void setRuleEnabled(int id, bool enabled);
  @async
  void deleteRule(int id);
  @async
  BacklogPreview previewRule(Rule rule);
  @async
  List<FolderInfo> suggestedFolders();
  @async
  List<FolderInfo> listFolder(String path);
  @async
  List<Topic> listTopics();
  @async
  Topic remakeTopic(int ruleId);
  @async
  void stopAllDeletes(); // kill switch

  // reviews
  @async
  Review? getReview(int ruleId); // the waiting one, or null
  @async
  Review previewDeletes(int ruleId); // what would be deleted now (no side effects)
  @async
  void approveReview(int reviewId);
  @async
  void dismissReview(int reviewId);

  // files and history
  @async
  EventPage listEvents(HistoryFilter filter, String? search, int? ruleId, int? cursor);
  @async
  FilePage listFiles(int ruleId, FileState? state, int? cursor);
  @async
  FileItem getFile(int id);
  @async
  void retryFile(int id);

  // settings
  @async
  AppSettings getSettings();
  @async
  void setAllowMobileData(bool on);
  @async
  void setGroupByDay(bool on);
  @async
  void setDocumentsTopic(int? topicId); // null turns the Documents topic off
  @async
  int createDocumentsTopic(); // makes the topic 'Documents' in the group, chooses it, returns its id
  @async
  void setDelayOptions(List<int> minutes);
  @async
  void setDefaultRetention(int days);
  @async
  void setSetupStep(String step);
  @async
  void finishSetup();
  @async
  String exportRules(); // JSON text
  @async
  int importRules(String json); // returns count

  // telegram
  @async
  BotInfo setBotToken(String token); // checks with getMe, stores in the secret store
  @async
  List<GroupCandidate> findGroups();
  @async
  GroupCheck checkGroup(int chatId);
  @async
  void selectGroup(int chatId); // saves + posts hello message
  @async
  TelegramState getTelegramState();
  @async
  void accountStart(int apiId, String apiHash);
  @async
  void accountPhone(String phone);
  @async
  void accountCode(String code);
  @async
  void accountPassword(String password);
  @async
  void accountResendCode();
  @async
  void accountLogout();
  @async
  int createSuggestedRules(List<String> suggestionPaths, StartMode startMode, int? startDate);

  // phone
  @async
  Permissions getPermissions();
  @async
  void openAllFilesSettings();
  @async
  void requestBatteryExemption();
  @async
  void openNotificationSettings();

  // help
  @async
  String diagnostics(); // redacted text

  // debug builds only (S-DEV); refused in release builds
  @async
  String devCommand(String command, String? argument);
}

// ---------- Flutter API: Kotlin calls Flutter (only while the UI is alive) ----------
@FlutterApi()
abstract class CoreEventsApi {
  void onStatus(Status status); // at most 2 per second
  void onTelegramState(TelegramState state); // login steps
  void onRulesChanged(); // UI reloads the list
  void onHistoryChanged();
  void onOpenRoute(String route); // a notification was tapped
}
