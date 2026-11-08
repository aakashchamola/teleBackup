import Foundation
import Network
import UIKit
import Photos
import UserNotifications
import BackgroundTasks
import TeleCore
import TeleTD

typealias CRule = TeleCore.Rule
typealias CFileRecord = TeleCore.FileRecord

/// Shows what the current run is doing (read by the Home screen and the notification).
final class RunTracker: ProgressSink {
    var running = false, pausing = false, scanning = false, cleaning = false
    var currentFileName: String?, bytesDone: Int64?, bytesTotal: Int64?
    var filesDone = 0, filesTotal = 0
    var onChange: (() -> Void)?
    private var lastTick = Date.distantPast

    func runStarted(filesTotal: Int, bytesTotal: Int64) { running = true; filesDone = 0; self.filesTotal = filesTotal; onChange?() }
    func fileStarted(name: String, bytesTotal: Int64, filesDone: Int, filesTotal: Int) {
        currentFileName = name; bytesDone = 0; self.bytesTotal = bytesTotal; self.filesDone = filesDone; self.filesTotal = filesTotal; onChange?()
    }
    func fileProgress(name: String, done: Int64, total: Int64) {
        bytesDone = done; bytesTotal = total
        if Date().timeIntervalSince(lastTick) > 0.5 { lastTick = Date(); onChange?() }
    }
    func fileFinished(filesDone: Int, filesTotal: Int) { self.filesDone = filesDone; self.filesTotal = filesTotal; onChange?() }
    func runEnded(_ reason: StopReason) { running = false; pausing = false; currentFileName = nil; bytesDone = nil; bytesTotal = nil; onChange?() }
}

final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private(set) var path: NWPath?
    var onBecameUsable: (() -> Void)?
    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self = self else { return }
            let was = self.path; self.path = p
            // Wi-Fi (or any network) came back: carry on by itself
            if p.status == .satisfied && (was?.status != .satisfied || was?.isExpensive != p.isExpensive) { self.onBecameUsable?() }
        }
        monitor.start(queue: DispatchQueue(label: "net"))
    }
    var online: Bool { path?.status == .satisfied }
    var unmetered: Bool { online && !(path?.isExpensive ?? true) }
}

/// Everything the iPhone app needs, built once. The core types come from the TeleCore package.
final class Runtime {
    static let shared = Runtime()

    let support: URL
    let store: Store
    let settings: Settings
    let clock: Clock = SystemClock()
    let events: EventLog
    let rules: RuleService
    let control: ControlService
    let source = PhotoLibrarySource()
    let exporter: PhotoExporter
    let scanner: LibraryScanner
    let pacer: Pacer
    let api: BotApi
    let gateway: TdlibGateway
    let accountAuth: AccountAuth
    let engine: UploadEngine
    let cleaner: Cleaner
    let tracker = RunTracker()
    let network = NetworkWatcher()
    var events_: CoreEventsApi?
    private var runTask: Task<Void, Never>?
    private var lastPrune: Int64 = 0
    private var delayTimer: Task<Void, Never>?
    private var pendingRoute: String?

    private init() {
        let fm = FileManager.default
        support = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        store = try! Store(path: support.appendingPathComponent("telebackup.sqlite").path)
        settings = Settings(store)
        #if DEBUG
        settings.debugBuild = true
        #endif
        events = EventLog(store, clock)
        rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        control = ControlService(settings: settings, events: events, clock: clock)
        exporter = PhotoExporter(dir: fm.temporaryDirectory.appendingPathComponent("scratch"))
        scanner = LibraryScanner(source: source, store: store, settings: settings, events: events, clock: clock)
        pacer = Pacer(clock: clock)
        api = BotApi(tokenProvider: { Keychain.get("bot.token") }, transport: URLSessionTransport(), scratch: fm.temporaryDirectory)
        let info = Bundle.main.infoDictionary
        gateway = TdlibGateway(appVersion: info?["CFBundleShortVersionString"] as? String ?? "1.0", deviceModel: UIDevice.current.model, systemVersion: UIDevice.current.systemVersion)
        let tdDir = support.appendingPathComponent("td")
        accountAuth = AccountAuth(gateway: gateway, settings: settings, secrets: KeychainSecrets(),
                                  folders: { (tdDir.appendingPathComponent("db").path, tdDir.appendingPathComponent("files").path) })
        engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: pacer, exporter: exporter,
                              hasher: Sha256Hasher(), sender: BotSender(api: api), control: control,
                              account: AccountSender(auth: accountAuth, gateway: gateway))
        cleaner = Cleaner(store: store, settings: settings, events: events, clock: clock, exporter: exporter, deleter: PhotoBatchDeleter())
        engine.progress = tracker
        BackgroundUploader.shared.api = api
        BackgroundUploader.shared.allowCellular = { [settings] in settings.allowMobileData || settings.mobileOnceUntilEmpty }
        engine.background = BackgroundUploader.shared   // bot uploads go to iOS's background session: they continue with the screen off
        engine.splitter = AVVideoSplitter()
        engine.scratchDir = fm.temporaryDirectory.appendingPathComponent("scratch").path
        let recheck = AccountRecheck(auth: accountAuth, gateway: gateway)
        cleaner.recheck = { await recheck.recheck($0) }
        accountAuth.onChange = { [weak self] in self?.pushTelegramState(); self?.pushStatus() }
        tracker.onChange = { [weak self] in guard let self = self else { return }; self.pushStatus(); if self.tracker.running { Notifier.shared.progress(self.tracker) } }
        exporter.clearScratch()   // leftovers of a killed run
        engine.converter = HeicConverter()
        cleaner.notifier = Notifier.shared
        network.onBecameUsable = { [weak self] in
            guard let self = self, self.settings.setupDone else { return }
            DispatchQueue.main.async { self.startRun(scan: false) }
        }
    }

    // MARK: running

    var networkAllows: Bool { settings.allowMobileData || settings.mobileOnceUntilEmpty || network.unmetered }

    /// Scans, uploads and prepares the delete review. Safe to call often: only one run goes at a time.
    func startRun(scan: Bool = true) {
        guard runTask == nil else { return }
        guard settings.setupDone, PhotoLibrarySource.authorized else { pushStatus(); return }
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "teleBackup upload") { [weak self] in
            self?.runTask?.cancel()   // iOS is taking the time back: the current file goes back to the queue
        }
        runTask = Task.detached(priority: .utility) { [self] in
            await performRun(scan: scan)
            runTask = nil
            pushStatus()
            if bg != .invalid { await UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    /// One run, start to end. Background tasks call this directly and wait for it.
    /// It takes care of the rest by itself: a delay that has ended is lifted, failed files are tried again when their waiting time is over,
    /// short waits are slept through, and the delete list, old history, warnings and the next wake-up are looked after at the end.
    func performRun(scan: Bool) async {
        if control.resumeIfDelayExpired() { Notifier.shared.clearControl() }
        if scan, accountAuth.hasLogin, let chat = settings.chatId {
            tracker.scanning = true; pushStatus()
            _ = await HistoryRestorer(store: store, gateway: gateway, auth: accountAuth).run(chatId: chat)   // first time on this phone only
            tracker.scanning = false
        }
        if scan { tracker.scanning = true; pushStatus(); for r in rules.active() where r.enabled { scanner.scan(r) }; tracker.scanning = false }
        var rounds = 0
        while rounds < 60 {
            rounds += 1
            if networkAllows { _ = await engine.run(isStopped: { Task.isCancelled }) }
            guard !Task.isCancelled, control.allowsRun, networkAllows, let at = store.earliestRetryAt() else { break }
            // a file that failed waits 2, 4, 8... minutes: sleep through the short waits, leave the long ones to a background wake-up
            let wait = at - clock.now()
            let patience = await MainActor.run { UIApplication.shared.applicationState == .active } ? 15 * Time.minute : 2 * Time.minute
            if wait > patience { break }
            var left = max(wait, 0) + 500
            while left > 0 && !Task.isCancelled && control.allowsRun { try? await Task.sleep(nanoseconds: 1_000_000_000); left -= 1000 }
        }
        cleaner.prepareReviews()
        if clock.now() - lastPrune > Time.day { lastPrune = clock.now(); _ = store.prune(before: clock.now() - 90 * Time.day) }
        afterRun()
    }

    /// Notifications, warnings and the next wake-up, after every run.
    func afterRun() {
        Notifier.shared.clearProgress()
        if settings.controlState != .running { Notifier.shared.showControlState() } else { Notifier.shared.clearControl() }
        Task { [self] in
            let att = await attention(now: clock.now(), waitingAccount: settings.accountState == .ready ? 0 : store.waitingAccountCount())
            Notifier.shared.raiseAttention(att)
        }
        BackgroundWork.schedule()
        armDelayTimer()
        pushStatus()
    }

    // MARK: pause, delay, resume (buttons in the app and in notifications)

    @MainActor func pauseNow() {
        control.pause(); delayTimer?.cancel(); tracker.pausing = tracker.running
        if !tracker.running { Notifier.shared.showControlState() }
        BackgroundWork.schedule(); pushStatus()
    }
    @MainActor func delayNow(minutes: Int) {
        control.delay(minutes: minutes); tracker.pausing = tracker.running
        if !tracker.running { Notifier.shared.showControlState() }
        armDelayTimer(); BackgroundWork.schedule(); pushStatus()
    }
    @MainActor func resumeNow() {
        control.resume(); delayTimer?.cancel(); Notifier.shared.clearControl()
        startRun(); BackgroundWork.schedule(); pushStatus()
    }

    /// While the app is alive, a delay ends on time by itself (a background wake-up covers the time the app is asleep).
    func armDelayTimer() {
        delayTimer?.cancel()
        guard settings.controlState == .delayed, let until = settings.delayedUntil else { return }
        delayTimer = Task { [weak self] in
            let ms = max(until - (self?.clock.now() ?? until), 0) + 1000
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.control.resumeIfDelayExpired() { Notifier.shared.clearControl(); await MainActor.run { self.startRun() } }
        }
    }

    // MARK: notification taps

    func openRoute(_ route: String) {
        guard let ev = events_ else { pendingRoute = route; return }
        Task { @MainActor in try? await ev.onOpenRoute(route: route) }
    }
    func flushPendingRoute() { if let r = pendingRoute { pendingRoute = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openRoute(r) } } }

    /// Telegram answered for a file the system uploaded in the background (the app may have just been woken for this).
    func backgroundFinished(fileId: Int64, code: Int, data: Data, error: Error?) {
        engine.completeBackground(fileId: fileId, httpCode: code, data: data, error: error)
        pushStatus()
        DispatchQueue.main.async { [self] in startRun(scan: false) }   // hand the next files to the system
    }

    var isRunning: Bool { runTask != nil }

    func cancelRun() { runTask?.cancel() }

    // MARK: status

    func pushStatus() {
        DispatchQueue.main.async { [self] in updateLiveActivity() }
        guard let ev = events_ else { return }
        Task { @MainActor in
            let s = await self.buildStatus()
            try? await ev.onStatus(status: s)
        }
    }

    /// Feeds the Dynamic Island / lock-screen counter. Called after every status change, also while the app is only awake in the background.
    func updateLiveActivity() {
        let c = store.stateCounts()
        let doneStates: Set<TeleCore.FileState> = [.uploaded, .verified, .deleted]
        let totalStates: Set<TeleCore.FileState> = [.queued, .uploading, .failed, .uploaded, .verified, .deleted]
        let done = c.filter { doneStates.contains($0.state) }.reduce(0) { $0 + $1.count }
        let total = c.filter { totalStates.contains($0.state) }.reduce(0) { $0 + $1.count }
        let inSystem = store.bgOutstanding().count > 0
        let busy = tracker.running || tracker.scanning || inSystem
        let name = tracker.currentFileName ?? (inSystem ? "Sending in the background" : "Working")
        LiveActivityController.shared.sync(done: done, total: total, current: name, busy: busy, waiting: !tracker.running && inSystem)
    }

    func permissionState() async -> (notifications: Bool, photos: Bool, backgroundRefresh: Bool) {
        let n = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let br = await MainActor.run { UIApplication.shared.backgroundRefreshStatus == .available }
        return (n == .authorized || n == .provisional, PhotoLibrarySource.authorized, br)
    }

    func buildStatus() async -> Status {
        let now = clock.now()
        let q = store.queueCount(now: now, allowBot: true, allowAccount: settings.accountState == .ready)
        let waitingAccount = settings.accountState == .ready ? 0 : store.waitingAccountCount()
        let cal = Calendar.current
        let midnight = Int64(cal.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let control = ControlState.from(settings.controlState.rawValue)
        var run: RunState = tracker.pausing ? .pausing : tracker.scanning ? .scanning : tracker.running ? .uploading : tracker.cleaning ? .cleaning : .idle
        if run == .idle, q.count > 0, settings.controlState == .running, settings.setupDone, !networkAllows { run = .waitingNetwork }
        return Status(control: control, delayedUntil: settings.delayedUntil, run: run, currentFileName: tracker.currentFileName,
                      currentFileBytesDone: tracker.bytesDone, currentFileBytesTotal: tracker.bytesTotal,
                      runFilesDone: Int64(tracker.filesDone), runFilesTotal: Int64(tracker.filesTotal), queuedCount: Int64(q.count), queuedBytes: q.bytes,
                      waitingAccountCount: Int64(waitingAccount), todayUploaded: Int64(store.uploadedCountSince(midnight)),
                      todayFreedBytes: store.freedBytesSince(midnight), todaySkipped: Int64(store.skippedCountSince(midnight)),
                      freedBytesTotal: store.freedBytesTotal(), lastScanAt: settings.lastScanAt, lastUploadAt: settings.lastUploadAt,
                      lastStopReason: settings.lastStopReason, attention: await attention(now: now, waitingAccount: waitingAccount),
                      onUnmeteredNetwork: network.unmetered)
    }

    func attention(now: Int64, waitingAccount: Int) async -> [Attention] {
        var out: [Attention] = []
        let p = await permissionState()
        if !settings.setupDone { out.append(Attention(kind: .setupNotDone, text: "Finish setup to start backing up.")) }
        if !p.photos { out.append(Attention(kind: .allFilesLost, text: "teleBackup can't reach your photos. Backup and delete are stopped.")) }
        if settings.accountState == .expired { out.append(Attention(kind: .loginExpired, text: "Your Telegram account was logged out. Log in again.")) }
        else if settings.accountState == .none && waitingAccount > 0 {
            out.append(Attention(kind: .bigFilesWaitAccount, text: "\(waitingAccount) big video\(waitingAccount == 1 ? "" : "s") wait for your Telegram account.", count: Int64(waitingAccount)))
        }
        if settings.setupDone && settings.botProblem { out.append(Attention(kind: .botProblem, text: "teleBackup can't post to your group. Add the bot back as admin.")) }
        for r in store.activeRules() {
            if let t = r.topicId, store.topic(threadId: t)?.missing == true { out.append(Attention(kind: .topicMissing, text: "\(r.name): the topic was deleted in Telegram.", ruleId: r.id)) }
        }
        for rv in store.allWaitingReviews() {
            guard let r = store.rule(id: rv.ruleId) else { continue }
            out.append(Attention(kind: .reviewWaiting, text: "\(r.name): \(rv.fileCount) files ready to delete. Check first.", ruleId: r.id, count: Int64(rv.fileCount)))
        }
        if !p.notifications { out.append(Attention(kind: .notificationsOff, text: "Notifications are off, so you won't see progress.")) }
        if !p.backgroundRefresh { out.append(Attention(kind: .batteryOptimized, text: "Background App Refresh is off, so backups only run while the app is open.")) }
        if let exp = settings.signatureExpiresAt, exp - now < 2 * Time.day {
            out.append(Attention(kind: .batteryOptimized, text: exp < now ? "This app's 7-day install has run out. Open LocalDevVPN (Connect), then SideStore, and refresh teleBackup." : "This app's 7-day install runs out soon. Open SideStore to refresh it."))
        }
        let skipped = store.skippedCountSince(now - 7 * Time.day)
        if skipped > 0 { out.append(Attention(kind: .skippedRecently, text: "\(skipped) file\(skipped == 1 ? "" : "s") skipped this week.", count: Int64(skipped))) }
        return out
    }
}

extension ControlState {
    static func from(_ raw: String) -> ControlState { ControlState.allCases.first { "\($0)" == raw } ?? .running }
}

extension Runtime {
    /// Apps signed with a free Apple ID stop opening after 7 days. The date is inside the embedded provisioning profile.
    func refreshSignature() {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard let r1 = text.range(of: "<key>ExpirationDate</key>"), let r2 = text.range(of: "<date>", range: r1.upperBound..<text.endIndex),
              let r3 = text.range(of: "</date>", range: r2.upperBound..<text.endIndex) else { return }
        let iso = String(text[r2.upperBound..<r3.lowerBound])
        guard let d = ISO8601DateFormatter().date(from: iso) else { return }
        let ms = Int64(d.timeIntervalSince1970 * 1000)
        settings.signatureExpiresAt = ms
        Notifier.shared.scheduleExpiryReminder(expiresAt: ms)
    }
}

struct KeychainSecrets: SecretStore {
    func get(_ key: String) -> String? { Keychain.get(key) }
    func put(_ key: String, _ value: String?) { Keychain.put(key, value) }
}

extension Runtime {
    func telegramState() -> TelegramState {
        let s = settings
        let bot = s.botId.map { BotInfo(id: $0, username: s.botUsername ?? "", name: "") }
        let group = s.chatId.map { GroupCheck(chatId: $0, title: s.chatTitle ?? "", topicsOn: true, botIsAdmin: true, botCanManageTopics: true) }
        let a = accountAuth.snapshot()
        return TelegramState(bot: bot, group: group, account: AccountState.allCases.first { "\($0)" == "\(a.step)" } ?? .none,
                             accountName: a.name ?? s.accountName, accountPhoneMasked: a.phoneMasked, codeSentTo: a.codeSentTo, passwordHint: a.passwordHint, lastError: a.lastError)
    }
    func pushTelegramState() {
        guard let ev = events_ else { return }
        let st = telegramState()
        Task { @MainActor in try? await ev.onTelegramState(state: st) }
    }
}
