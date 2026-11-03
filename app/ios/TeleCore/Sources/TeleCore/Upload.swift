import Foundation

/// Gets a copy of one library item into our scratch folder (downloads it from iCloud if needed).
public struct ExportedFile { public var path: String; public var sizeBytes: Int64; public init(path: String, sizeBytes: Int64) { self.path = path; self.sizeBytes = sizeBytes } }
public protocol AssetExporter {
    func export(_ assetId: String, displayName: String) async throws -> ExportedFile
    func facts(_ assetId: String) -> DiskFacts
}
public protocol Hasher { func sha256(path: String) throws -> String }

public protocol ProgressSink: AnyObject {
    func runStarted(filesTotal: Int, bytesTotal: Int64)
    func fileStarted(name: String, bytesTotal: Int64, filesDone: Int, filesTotal: Int)
    func fileProgress(name: String, done: Int64, total: Int64)
    func fileFinished(filesDone: Int, filesTotal: Int)
    func runEnded(_ reason: StopReason)
}
public extension ProgressSink {
    func runStarted(filesTotal: Int, bytesTotal: Int64) {}
    func fileStarted(name: String, bytesTotal: Int64, filesDone: Int, filesTotal: Int) {}
    func fileProgress(name: String, done: Int64, total: Int64) {}
    func fileFinished(filesDone: Int, filesTotal: Int) {}
    func runEnded(_ reason: StopReason) {}
}

public enum StopReason: String { case queueEmpty, paused, osStopped, noInternet, notSetUp, nothingToSend }
public struct RunOutcome: Equatable { public var filesDone: Int; public var reason: StopReason }

/// One upload run (docs/HOW_IT_WORKS.md section 5). On iPhone a run is as long as iOS lets the app run;
/// everything is saved per file, so the next run (or the next background window) carries on.
public final class UploadEngine {
    let store: Store, settings: Settings, events: EventLog, clock: Clock, pacer: Pacer
    let exporter: AssetExporter, hasher: Hasher, sender: TelegramSender, control: ControlService
    let account: TelegramSender?
    private var accountStopped = false
    private var botStopped = false
    public weak var progress: ProgressSink?
    private var pausedRules = Set<Int64>()
    private var networkFails = 0

    public init(store: Store, settings: Settings, events: EventLog, clock: Clock, pacer: Pacer, exporter: AssetExporter,
                hasher: Hasher, sender: TelegramSender, control: ControlService, account: TelegramSender? = nil) {
        self.account = account
        self.store = store; self.settings = settings; self.events = events; self.clock = clock; self.pacer = pacer
        self.exporter = exporter; self.hasher = hasher; self.sender = sender; self.control = control
    }

    public func run(isStopped: @escaping () -> Bool = { false }) async -> RunOutcome {
        guard control.allowsRun else { return end(0, .paused, started: false) }
        guard settings.chatId != nil else { return end(0, .notSetUp, started: false) }
        recoverInterrupted()
        accountStopped = false; botStopped = false
        let total0 = store.queueCount(now: clock.now(), allowBot: true, allowAccount: accountReady)
        progress?.runStarted(filesTotal: total0.count, bytesTotal: total0.bytes)
        var done = 0; var reason = StopReason.queueEmpty
        while true {
            if isStopped() || Task.isCancelled { reason = .osStopped; break }
            if !control.allowsRun { reason = .paused; break }
            guard let file = store.nextInQueue(now: clock.now(), allowBot: !botStopped, allowAccount: accountReady, excludeRuleIds: pausedRules) else {
                reason = (store.waitingAccountCount() > 0 || botStopped) ? .nothingToSend : .queueEmpty; break
            }
            guard let rule = store.rule(id: file.ruleId), rule.enabled, rule.deletedAt == nil else {
                _ = try? store.apply(file.id, .ignore, now: clock.now()); continue
            }
            switch await sendOne(file, rule, done: done, total: total0.count) {
            case .done: done += 1; networkFails = 0; progress?.fileFinished(filesDone: done, filesTotal: total0.count)
            case .retry: break
            case .networkFail:
                networkFails += 1
                if networkFails >= 3 { reason = .noInternet }
            }
            if reason == .noInternet { break }
        }
        if reason == .queueEmpty { settings.mobileOnceUntilEmpty = false }
        settings.lastUploadAt = clock.now()
        return end(done, reason, started: true)
    }

    var accountReady: Bool { settings.accountState == .ready && !accountStopped && account != nil }

    private func end(_ done: Int, _ reason: StopReason, started: Bool) -> RunOutcome {
        settings.lastStopReason = reason.rawValue
        if started { progress?.runEnded(reason) }
        return RunOutcome(filesDone: done, reason: reason)
    }

    /// Rows left in `uploading` by a kill become queued, or uploaded if Telegram had already answered.
    func recoverInterrupted() {
        for f in store.interrupted() {
            if let after = try? store.apply(f.id, .recoverAfterCrash, now: clock.now()), after.state == .uploaded, let rule = store.rule(id: after.ruleId) {
                verify(after, rule, job: nil)
            }
        }
    }

    enum Step { case done, retry, networkFail }

    func sendOne(_ file0: FileRecord, _ rule: Rule, done: Int, total: Int) async -> Step {
        await pacer.awaitSlot(file0.route ?? .bot)
        var file = file0
        let now0 = clock.now()
        let facts = exporter.facts(file.path)
        if !facts.exists {
            _ = try? store.apply(file.id, .vanished, now: now0)
            events.add(.gone, "\(file.displayName) was removed from the phone", ruleId: rule.id, fileId: file.id)
            return .retry
        }
        if facts.sizeBytes != file.sizeBytes || facts.modifiedAt != file.modifiedAt {
            file.sizeBytes = facts.sizeBytes; file.modifiedAt = facts.modifiedAt; file.sha256 = nil
            store.updateDetails(file); return .retry
        }
        do {
            if file.state == .failed { file = try store.apply(file.id, .backoffDue, now: clock.now()) }
            file = try store.apply(file.id, .startUpload, now: clock.now())
        } catch { return .retry }
        progress?.fileStarted(name: file.displayName, bytesTotal: file.sizeBytes, filesDone: done, filesTotal: total)

        let exported: ExportedFile
        do { exported = try await exporter.export(file.path, displayName: file.displayName) }
        catch {
            // iCloud download failed or no connection: try again later without counting it against the file
            _ = try? store.apply(file.id, .networkStop, now: clock.now()); return .networkFail
        }
        defer { try? FileManager.default.removeItem(atPath: exported.path) }
        guard let hash = (try? file.sha256 ?? hasher.sha256(path: exported.path)) else {
            _ = try? store.apply(file.id, .vanished, now: clock.now()); return .retry
        }
        if file.sha256 == nil { var u = file; u.sha256 = hash; store.updateDetails(u) }
        let job = SendJob(chatId: settings.chatId!, threadId: file.topicId ?? rule.topicId, path: exported.path, displayName: file.displayName,
                          mimeType: file.mimeType, sendAs: file.sendAs ?? .document,
                          caption: Caption.build(displayName: file.displayName, takenAt: file.takenAt, ruleName: rule.name, sha256: hash),
                          sizeBytes: exported.sizeBytes, width: file.width, height: file.height, durationMs: file.durationMs)
        let name = file.displayName
        let route = file.route ?? .bot
        guard let chosen = route == .account ? account : sender else {
            _ = try? store.apply(file.id, .networkStop, now: clock.now())
            if route == .account { accountStopped = true } else { botStopped = true }
            return .retry
        }
        let result = await chosen.send(job) { [weak self] s, t in self?.progress?.fileProgress(name: name, done: s, total: t) }
        return complete(file.id, result, job: job, hash: hash)
    }

    /// Records what Telegram answered. Shared by the foreground loop and the background-session path.
    @discardableResult
    func complete(_ fileId: Int64, _ result: SendResult, job: SendJob, hash: String?) -> Step {
        guard let file = store.file(id: fileId), let rule = store.rule(id: file.ruleId) else { return .retry }
        switch result {
        case .sent(let msg):
            settings.botProblem = false
            guard let uploaded = try? store.apply(file.id, .sent(msg, sha256: hash), now: clock.now()) else { return .retry }
            events.add(.uploaded, "\(file.displayName) uploaded", ruleId: rule.id, fileId: file.id, bytes: file.sizeBytes)
            verify(uploaded, rule, job: job, sent: msg)
            return .done
        case .failed(let err): return handleFailure(file, rule, err)
        }
    }

    func verify(_ file: FileRecord, _ rule: Rule, job: SendJob?, sent: SentMessage? = nil) {
        let now = clock.now()
        // after a crash there is no job to compare with: the reply was already saved on the row, so trust its fields
        let check: ReplyCheck
        if let job = job, let sent = sent { check = Verifier.checkReply(job, sent) }
        else if file.tgMessageId != nil, file.tgChatId != nil { check = .ok }
        else { check = .mismatch("no reply saved") }
        switch check {
        case .ok:
            let due = rule.mode == .uploadAndDelete ? Retention.deleteAfter(verifiedAt: now, retentionDays: rule.retentionDays, timeWarp: settings.timeWarp) : nil
            _ = try? store.apply(file.id, .replyOk(deleteAfter: due), now: now)
            events.add(.verified, "\(file.displayName) checked in Telegram", ruleId: rule.id, fileId: file.id)
        case .mismatch(let why):
            _ = try? store.apply(file.id, .replyMismatch(why), now: now, maxAttempts: settings.maxAttempts, jitter: Double.random(in: 0...1))
            events.add(.verifyFailed, "\(file.displayName): Telegram reply did not match (\(why))", ruleId: rule.id, fileId: file.id)
        }
    }

    func handleFailure(_ file: FileRecord, _ rule: Rule, _ err: TgError) -> Step {
        let now = clock.now()
        let after = try? store.apply(file.id, .tgFailed(err), now: now, maxAttempts: settings.maxAttempts, jitter: Double.random(in: 0...1))
        switch err {
        case .floodWait(let s):
            if file.route == .account { pacer.blockRoute(.account, until: now + (s + 1) * 1000) } else { pacer.blockAll(until: now + (s + 1) * 1000) }
            return .retry
        case .accountLoggedOut:
            accountStopped = true; settings.accountState = .expired
            events.add(.loginExpired, "The Telegram account is logged out")
            return .retry
        case .network: return .networkFail
        case .topicMissing:
            if let t = rule.topicId { store.markMissing(threadId: t, true) }
            pausedRules.insert(rule.id)
            events.add(.topicMissing, "\(rule.name): the topic was deleted in Telegram", ruleId: rule.id)
            return .retry
        case .badToken, .forbidden:
            botStopped = true
            settings.botProblem = true
            events.add(.botProblem, err.userMessage, ruleId: rule.id)
            return .networkFail
        case .chatMigrated(let new): settings.chatId = new; return .retry
        default:
            if after?.state == .skipped { events.add(.skipped, "\(file.displayName) skipped: \(err.userMessage)", ruleId: rule.id, fileId: file.id) }
            else { events.add(.failed, "\(file.displayName): \(err.userMessage)", ruleId: rule.id, fileId: file.id) }
            return .retry
        }
    }
}
