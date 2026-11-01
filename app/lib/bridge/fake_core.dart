import 'dart:async';

import 'core.dart';

/// An in-memory stand-in for the Kotlin core. Used by the widget tests and by `flutter run` without a phone.
/// Its answers follow the real core's rules closely enough for the screens (names are unique, delete needs the warning, ...).
class FakeCore extends CoreHostApi {
  FakeCore({CoreEvents? events}) : events = events ?? CoreEvents() {
    status = defaultStatus();
  }

  final CoreEvents events;
  final List<String> calls = [];
  AppError? failNext;

  late Status status;
  AppSettings settings = AppSettings(
    allowMobileData: false,
    delayOptionsMinutes: [120, 300],
    defaultRetentionDays: 7,
    setupDone: true,
    setupStep: 'O7',
    debugBuild: true,
  );
  final List<RuleWithStats> rules = [];
  int _nextRuleId = 1;
  List<Topic> topics = [
    Topic(threadId: 11, name: 'Gallery photos', missing: false, madeByApp: true),
    Topic(threadId: 12, name: 'Screenshots', missing: false, madeByApp: true),
  ];
  List<FolderInfo> suggested = [
    FolderInfo(path: 'DCIM/Camera/?types=photos', label: 'Gallery photos', mediaCount: 1204, isSuggestion: true),
    FolderInfo(path: 'DCIM/Camera/?types=videos', label: 'Gallery videos', mediaCount: 88, isSuggestion: true),
    FolderInfo(path: 'Pictures/Screenshots/?types=both', label: 'Screenshots', mediaCount: 640, isSuggestion: true),
    FolderInfo(path: 'Telegram/Telegram Images/?types=photos', label: 'Telegram images', mediaCount: 12, isSuggestion: true, hint: 'These came from Telegram already.'),
  ];
  List<FolderInfo> folders = [
    FolderInfo(path: 'DCIM/', label: 'DCIM', mediaCount: 0, isSuggestion: false),
    FolderInfo(path: 'Download/', label: 'Download', mediaCount: 3, isSuggestion: false),
    FolderInfo(path: 'Pictures/', label: 'Pictures', mediaCount: 0, isSuggestion: false),
  ];
  TelegramState telegram = TelegramState(account: AccountState.none);
  Permissions permissions = Permissions(notifications: true, allFiles: true, batteryExempt: true, mediaRead: true);
  List<GroupCandidate> groups = [GroupCandidate(chatId: -1001, title: 'My photos backup')];
  GroupCheck groupCheck = GroupCheck(chatId: -1001, title: 'My photos backup', topicsOn: true, botIsAdmin: true, botCanManageTopics: true);
  Review? waitingReview;
  List<EventItem> eventItems = [];
  List<FileItem> fileItems = [];
  String diagText = 'No passwords, tokens or phone numbers are included.\n\nteleBackup 1.0.0 (1)';
  String validToken = '123456:valid-token';
  BacklogPreview preview = BacklogPreview(count: 12, bytes: 3400000);

  static Status defaultStatus() => Status(
        control: ControlState.running,
        run: RunState.idle,
        runFilesDone: 0,
        runFilesTotal: 0,
        queuedCount: 0,
        queuedBytes: 0,
        waitingAccountCount: 0,
        todayUploaded: 0,
        todayFreedBytes: 0,
        todaySkipped: 0,
        freedBytesTotal: 0,
        attention: [],
        onUnmeteredNetwork: true,
      );

  void _call(String name) {
    calls.add(name);
    final e = failNext;
    if (e != null) {
      failNext = null;
      throw e;
    }
  }

  /// Change the status the screens see and tell them, like the real core does.
  void setStatus(Status s) {
    status = s;
    events.status.add(s);
  }

  RuleWithStats addRule(Rule rule, {RuleStats? stats}) {
    final id = _nextRuleId++;
    rule.id = id;
    final r = RuleWithStats(
      rule: rule,
      stats: stats ?? RuleStats(ruleId: id, queued: 0, backedUp: 0, backedUpBytes: 0, waitingDelete: 0, deleted: 0, freedBytes: 0, skipped: 0, topicMissing: false),
    );
    rules.add(r);
    return r;
  }

  static Rule newRule({String name = 'Rule', String folder = 'DCIM/Camera/', RuleMode mode = RuleMode.uploadOnly}) => Rule(
        name: name,
        folderPath: folder,
        includeSubfolders: false,
        mediaTypes: MediaTypes.both,
        uploadAs: UploadAs.media,
        mode: mode,
        retentionDays: 7,
        startMode: StartMode.today,
        enabled: true,
        dryRun: true,
        deleteWarningAccepted: mode == RuleMode.uploadAndDelete,
      );

  // ----- status and controls -----

  @override
  Future<Status> getStatus() async {
    _call('getStatus');
    return status;
  }

  @override
  Future<void> pause() async {
    _call('pause');
    setStatus(_copy(status, control: ControlState.paused));
  }

  @override
  Future<void> resume() async {
    _call('resume');
    setStatus(_copy(status, control: ControlState.running, clearDelay: true));
  }

  @override
  Future<void> delay(int minutes) async {
    _call('delay:$minutes');
    setStatus(_copy(status, control: ControlState.delayed, delayedUntil: DateTime.now().millisecondsSinceEpoch + minutes * 60000));
  }

  @override
  Future<void> scanNow(int? ruleId) async => _call('scanNow:$ruleId');

  @override
  Future<void> uploadNow(bool mobileDataOnce) async => _call('uploadNow:$mobileDataOnce');

  // ----- rules -----

  @override
  Future<List<RuleWithStats>> listRules() async {
    _call('listRules');
    return List.of(rules);
  }

  @override
  Future<RuleWithStats> getRule(int id) async {
    _call('getRule:$id');
    return rules.firstWhere((r) => r.rule.id == id, orElse: () => throw AppError('VALIDATION', 'That rule is gone.'));
  }

  @override
  Future<int> saveRule(Rule rule) async {
    _call('saveRule');
    final name = rule.name.trim();
    if (name.isEmpty) throw AppError('VALIDATION', 'Give the rule a name.', 'name');
    if (rule.folderPath.trim().isEmpty) throw AppError('VALIDATION', 'Pick a folder.', 'folder');
    if (rules.any((r) => r.rule.id != rule.id && r.rule.name.toLowerCase() == name.toLowerCase())) {
      throw AppError('VALIDATION', 'This name is already used.', 'name');
    }
    if (rule.mode == RuleMode.uploadAndDelete && !rule.deleteWarningAccepted) {
      throw AppError('VALIDATION', 'Turn on delete from the warning first.', 'mode');
    }
    if (rule.newTopicName != null) {
      final t = Topic(threadId: 100 + topics.length, name: rule.newTopicName!, missing: false, madeByApp: true);
      topics = [...topics, t];
      rule.topicId = t.threadId;
      rule.newTopicName = null;
    }
    if (rule.id == null) {
      return addRule(rule).rule.id!;
    }
    final i = rules.indexWhere((r) => r.rule.id == rule.id);
    rules[i] = RuleWithStats(rule: rule, stats: rules[i].stats);
    events.rulesChanged.add(null);
    return rule.id!;
  }

  @override
  Future<void> setRuleEnabled(int id, bool enabled) async {
    _call('setRuleEnabled:$id:$enabled');
    rules.firstWhere((r) => r.rule.id == id).rule.enabled = enabled;
  }

  @override
  Future<void> deleteRule(int id) async {
    _call('deleteRule:$id');
    rules.removeWhere((r) => r.rule.id == id);
  }

  @override
  Future<BacklogPreview> previewRule(Rule rule) async {
    _call('previewRule');
    return preview;
  }

  @override
  Future<List<FolderInfo>> suggestedFolders() async {
    _call('suggestedFolders');
    return suggested;
  }

  @override
  Future<List<FolderInfo>> listFolder(String path) async {
    _call('listFolder:$path');
    return path.isEmpty ? folders : [FolderInfo(path: '${path}Camera/', label: 'Camera', mediaCount: 2, isSuggestion: false)];
  }

  @override
  Future<List<Topic>> listTopics() async {
    _call('listTopics');
    return topics;
  }

  @override
  Future<Topic> remakeTopic(int ruleId) async {
    _call('remakeTopic:$ruleId');
    final i = rules.indexWhere((r) => r.rule.id == ruleId);
    final t = Topic(threadId: 500 + ruleId, name: rules[i].rule.name, missing: false, madeByApp: true);
    topics = [...topics, t];
    rules[i].rule.topicId = t.threadId;
    rules[i].stats.topicMissing = false;
    return t;
  }

  @override
  Future<void> stopAllDeletes() async {
    _call('stopAllDeletes');
    for (final r in rules) {
      r.rule.mode = RuleMode.uploadOnly;
      r.rule.deleteWarningAccepted = false;
    }
    waitingReview = null;
  }

  // ----- reviews -----

  @override
  Future<Review?> getReview(int ruleId) async {
    _call('getReview:$ruleId');
    return waitingReview?.ruleId == ruleId ? waitingReview : null;
  }

  @override
  Future<Review> previewDeletes(int ruleId) async {
    _call('previewDeletes:$ruleId');
    final w = waitingReview;
    return Review(id: 0, ruleId: ruleId, ruleName: w?.ruleName ?? 'Rule', fileCount: w?.fileCount ?? 0, totalBytes: w?.totalBytes ?? 0, files: w?.files ?? [], preview: true);
  }

  @override
  Future<void> approveReview(int reviewId) async {
    _call('approveReview:$reviewId');
    waitingReview = null;
  }

  @override
  Future<void> dismissReview(int reviewId) async {
    _call('dismissReview:$reviewId');
    waitingReview = null;
  }

  // ----- files and history -----

  @override
  Future<EventPage> listEvents(HistoryFilter filter, String? search, int? ruleId, int? cursor) async {
    _call('listEvents:${filter.name}');
    var items = eventItems.where((e) {
      switch (filter) {
        case HistoryFilter.all:
          return true;
        case HistoryFilter.uploaded:
          return e.kind == 'UPLOADED' || e.kind == 'VERIFIED';
        case HistoryFilter.deleted:
          return e.kind == 'DELETED';
        case HistoryFilter.skipped:
          return e.kind == 'SKIPPED';
        case HistoryFilter.problems:
          return const {'FAILED', 'SKIPPED', 'VERIFY_FAILED', 'DELETE_DENIED'}.contains(e.kind);
      }
    }).toList();
    if (search != null && search.isNotEmpty) items = items.where((e) => e.message.toLowerCase().contains(search.toLowerCase())).toList();
    if (ruleId != null) items = items.where((e) => e.ruleId == ruleId).toList();
    if (cursor != null) items = items.where((e) => e.id < cursor).toList();
    final page = items.take(50).toList();
    return EventPage(items: page, nextCursor: items.length > 50 ? page.last.id : null);
  }

  @override
  Future<FilePage> listFiles(int ruleId, FileState? state, int? cursor) async {
    _call('listFiles:$ruleId');
    final items = fileItems.where((f) => f.ruleId == ruleId && (state == null || f.state == state)).toList();
    return FilePage(items: items.take(50).toList());
  }

  @override
  Future<FileItem> getFile(int id) async {
    _call('getFile:$id');
    return fileItems.firstWhere((f) => f.id == id, orElse: () => throw AppError('VALIDATION', 'That file is gone.'));
  }

  @override
  Future<void> retryFile(int id) async => _call('retryFile:$id');

  // ----- settings -----

  @override
  Future<AppSettings> getSettings() async {
    _call('getSettings');
    return settings;
  }

  @override
  Future<void> setAllowMobileData(bool on) async {
    _call('setAllowMobileData:$on');
    settings.allowMobileData = on;
  }

  @override
  Future<void> setDelayOptions(List<int> minutes) async {
    _call('setDelayOptions');
    if (minutes.isEmpty || minutes.length > 4 || minutes.any((m) => m < 15 || m > 1440)) {
      throw AppError('VALIDATION', 'Use 1 to 4 options, each between 15 minutes and 24 hours.');
    }
    settings.delayOptionsMinutes = minutes;
  }

  @override
  Future<void> setDefaultRetention(int days) async {
    _call('setDefaultRetention:$days');
    if (days < 1 || days > 365) throw AppError('VALIDATION', 'Use 1 to 365 days.');
    settings.defaultRetentionDays = days;
  }

  @override
  Future<void> setSetupStep(String step) async {
    _call('setSetupStep:$step');
    settings.setupStep = step;
  }

  @override
  Future<void> finishSetup() async {
    _call('finishSetup');
    settings.setupDone = true;
  }

  @override
  Future<String> exportRules() async {
    _call('exportRules');
    return '{"format":"telebackup-rules","version":1}';
  }

  @override
  Future<int> importRules(String json) async {
    _call('importRules');
    if (!json.contains('telebackup-rules')) throw AppError('VALIDATION', 'That is not a teleBackup rules file.');
    return 1;
  }

  // ----- telegram -----

  @override
  Future<BotInfo> setBotToken(String token) async {
    _call('setBotToken');
    if (token != validToken) throw AppError('TELEGRAM', 'That token did not work. Copy it again from BotFather.');
    final bot = BotInfo(id: 42, username: 'family_photos_bot', name: 'Family');
    telegram = TelegramState(bot: bot, group: telegram.group, account: telegram.account);
    return bot;
  }

  @override
  Future<List<GroupCandidate>> findGroups() async {
    _call('findGroups');
    return groups;
  }

  @override
  Future<GroupCheck> checkGroup(int chatId) async {
    _call('checkGroup:$chatId');
    return groupCheck;
  }

  @override
  Future<void> selectGroup(int chatId) async {
    _call('selectGroup:$chatId');
    if (!(groupCheck.topicsOn && groupCheck.botIsAdmin && groupCheck.botCanManageTopics)) {
      throw AppError('TELEGRAM', 'The group is not ready yet.');
    }
    telegram = TelegramState(bot: telegram.bot, group: groupCheck, account: telegram.account);
  }

  @override
  Future<TelegramState> getTelegramState() async {
    _call('getTelegramState');
    return telegram;
  }

  @override
  Future<void> accountStart(int apiId, String apiHash) async {
    _call('accountStart');
    telegram = TelegramState(bot: telegram.bot, group: telegram.group, account: AccountState.waitPhone);
    events.telegram.add(telegram);
  }

  @override
  Future<void> accountPhone(String phone) async {
    _call('accountPhone');
    telegram = TelegramState(bot: telegram.bot, group: telegram.group, account: AccountState.waitCode, accountPhoneMasked: '+91 ••••• ••123', codeSentTo: 'Telegram app');
    events.telegram.add(telegram);
  }

  @override
  Future<void> accountCode(String code) async {
    _call('accountCode');
    if (code != '12345') {
      telegram = TelegramState(bot: telegram.bot, group: telegram.group, account: AccountState.waitCode, lastError: 'Wrong code.');
    } else {
      telegram = TelegramState(bot: telegram.bot, group: telegram.group, account: AccountState.ready, accountName: 'Aakash', accountPhoneMasked: '+91 ••••• ••123');
    }
    events.telegram.add(telegram);
  }

  @override
  Future<void> accountPassword(String password) async => _call('accountPassword');

  @override
  Future<void> accountResendCode() async => _call('accountResendCode');

  @override
  Future<void> accountLogout() async {
    _call('accountLogout');
    telegram = TelegramState(bot: telegram.bot, group: telegram.group, account: AccountState.none);
    events.telegram.add(telegram);
  }

  @override
  Future<int> createSuggestedRules(List<String> suggestionPaths, StartMode startMode, int? startDate) async {
    _call('createSuggestedRules:${suggestionPaths.length}');
    for (final p in suggestionPaths) {
      final s = suggested.firstWhere((f) => f.path == p);
      addRule(newRule(name: s.label, folder: p.split('?').first));
    }
    return suggestionPaths.length;
  }

  // ----- phone -----

  @override
  Future<Permissions> getPermissions() async {
    _call('getPermissions');
    return permissions;
  }

  @override
  Future<void> openAllFilesSettings() async => _call('openAllFilesSettings');

  @override
  Future<void> requestBatteryExemption() async => _call('requestBatteryExemption');

  @override
  Future<void> openNotificationSettings() async => _call('openNotificationSettings');

  @override
  Future<String> diagnostics() async {
    _call('diagnostics');
    return diagText;
  }

  @override
  Future<String> devCommand(String command, String? argument) async {
    _call('dev:$command');
    return 'ok: $command';
  }

  // ----- helpers -----

  static Status _copy(Status s, {ControlState? control, int? delayedUntil, bool clearDelay = false}) => Status(
        control: control ?? s.control,
        delayedUntil: clearDelay ? null : (delayedUntil ?? s.delayedUntil),
        run: s.run,
        currentFileName: s.currentFileName,
        currentFileBytesDone: s.currentFileBytesDone,
        currentFileBytesTotal: s.currentFileBytesTotal,
        runFilesDone: s.runFilesDone,
        runFilesTotal: s.runFilesTotal,
        queuedCount: s.queuedCount,
        queuedBytes: s.queuedBytes,
        waitingAccountCount: s.waitingAccountCount,
        todayUploaded: s.todayUploaded,
        todayFreedBytes: s.todayFreedBytes,
        todaySkipped: s.todaySkipped,
        freedBytesTotal: s.freedBytesTotal,
        lastScanAt: s.lastScanAt,
        lastUploadAt: s.lastUploadAt,
        lastStopReason: s.lastStopReason,
        attention: s.attention,
        onUnmeteredNetwork: s.onUnmeteredNetwork,
      );
}

/// A status with every field set, for tests: change what the test cares about with [statusWith].
Status statusWith({
  ControlState control = ControlState.running,
  int? delayedUntil,
  RunState run = RunState.idle,
  String? currentFileName,
  int? bytesDone,
  int? bytesTotal,
  int filesDone = 0,
  int filesTotal = 0,
  int queuedCount = 0,
  int queuedBytes = 0,
  int waitingAccount = 0,
  int todayUploaded = 0,
  int todayFreed = 0,
  int todaySkipped = 0,
  int freedTotal = 0,
  int? lastScanAt,
  int? lastUploadAt,
  String? lastStopReason,
  List<Attention> attention = const [],
  bool unmetered = true,
}) =>
    Status(
      control: control,
      delayedUntil: delayedUntil,
      run: run,
      currentFileName: currentFileName,
      currentFileBytesDone: bytesDone,
      currentFileBytesTotal: bytesTotal,
      runFilesDone: filesDone,
      runFilesTotal: filesTotal,
      queuedCount: queuedCount,
      queuedBytes: queuedBytes,
      waitingAccountCount: waitingAccount,
      todayUploaded: todayUploaded,
      todayFreedBytes: todayFreed,
      todaySkipped: todaySkipped,
      freedBytesTotal: freedTotal,
      lastScanAt: lastScanAt,
      lastUploadAt: lastUploadAt,
      lastStopReason: lastStopReason,
      attention: List.of(attention),
      onUnmeteredNetwork: unmetered,
    );
