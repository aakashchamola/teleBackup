import Foundation

/// Gets a copy of one library item into our scratch folder (downloads it from iCloud if needed).
public struct ExportedFile { public var path: String; public var sizeBytes: Int64; public init(path: String, sizeBytes: Int64) { self.path = path; self.sizeBytes = sizeBytes } }
public protocol AssetExporter {
    func export(_ assetId: String, displayName: String) async throws -> ExportedFile
    func facts(_ assetId: String) -> DiskFacts
}
public protocol Hasher { func sha256(path: String) throws -> String }
/// HEIC/HEIF to JPEG, small enough for Telegram's photo limit. False when it cannot be done (the original then goes as a file).
public protocol ImageConverter { func toJpeg(source: String, dest: String, maxBytes: Int64) -> Bool }

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

/// iOS's own background upload session: the system keeps sending after the app is suspended and wakes the app when Telegram has answered.
public protocol BackgroundUploading: AnyObject {
    /// Writes the request body to a file the system can read and starts the upload. Returns that file's path, or nil if it could not be prepared.
    func submit(_ job: SendJob, fileId: Int64) -> String?
    /// File ids of uploads the system is still carrying out.
    func activeFileIds() async -> Set<Int64>
    /// Stops every upload the system is carrying out (the engine puts those files back in the queue).
    func cancelAll()
}

/// The few fields of a `SendJob` needed to check Telegram's reply after a background upload.
enum BgJobCodec {
    static func encode(_ j: SendJob) -> String {
        var d: [String: Any] = ["chat": j.chatId, "name": j.displayName, "mime": j.mimeType, "as": j.sendAs.rawValue, "cap": j.caption, "size": j.sizeBytes]
        if let t = j.threadId { d["thread"] = t }
        if let w = j.width { d["w"] = w }; if let h = j.height { d["h"] = h }; if let u = j.durationMs { d["dur"] = u }
        return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static func decode(_ s: String) -> SendJob? {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let chat = (d["chat"] as? NSNumber)?.int64Value, let asRaw = d["as"] as? String, let sendAs = SendAs(rawValue: asRaw) else { return nil }
        return SendJob(chatId: chat, threadId: (d["thread"] as? NSNumber)?.int64Value, path: "", displayName: d["name"] as? String ?? "", mimeType: d["mime"] as? String ?? "",
                       sendAs: sendAs, caption: d["cap"] as? String ?? "", sizeBytes: (d["size"] as? NSNumber)?.int64Value ?? 0,
                       width: (d["w"] as? NSNumber)?.intValue, height: (d["h"] as? NSNumber)?.intValue, durationMs: (d["dur"] as? NSNumber)?.int64Value)
    }
}

public enum StopReason: String { case queueEmpty, paused, osStopped, noInternet, notSetUp, nothingToSend }
public struct RunOutcome: Equatable { public var filesDone: Int; public var reason: StopReason }

/// One upload run (docs/HOW_IT_WORKS.md section 5). On iPhone a run is as long as iOS lets the app run;
/// everything is saved per file, so the next run (or the next background window) carries on.
public final class UploadEngine {
    let store: Store, settings: Settings, events: EventLog, clock: Clock, pacer: Pacer
    let exporter: AssetExporter, hasher: Hasher, sender: TelegramSender, control: ControlService
    let account: TelegramSender?
    public var splitter: VideoSplitter?
    public var converter: ImageConverter?
    public var scratchDir: String?
    private var accountStopped = false
    private var botStopped = false
    public weak var progress: ProgressSink?
    private var pausedRules = Set<Int64>()
    private var networkFails = 0
    /// Set to hand bot uploads to iOS's background session instead of waiting for each one.
    public var background: BackgroundUploading?
    public var handoffMaxBytes: Int64 = 300_000_000, handoffMaxFiles = 40   // smaller batches: more completions, so iOS wakes the app more often
    private var handoffFull = false

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
        accountStopped = false; botStopped = false; handoffFull = false
        await reconcileBackground()
        let total0 = store.queueCount(now: clock.now(), allowBot: true, allowAccount: accountReady)
        progress?.runStarted(filesTotal: total0.count, bytesTotal: total0.bytes)
        var done = 0; var reason = StopReason.queueEmpty
        while true {
            if isStopped() || Task.isCancelled { reason = .osStopped; break }
            if !control.allowsRun { reason = .paused; break }
            guard let file = store.nextInQueue(now: clock.now(), allowBot: !botStopped && !handoffFull, allowAccount: accountReady, excludeRuleIds: pausedRules) else {
                reason = (store.waitingAccountCount() > 0 || botStopped || handoffFull) ? .nothingToSend : .queueEmpty; break
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
        for f in store.interrupted() where store.bgJob(f.id) == nil {   // a file the system is still sending is not interrupted
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
        var sendAs = file.sendAs ?? .document
        var sendPath = exported.path, sendName = file.displayName, sendMime = file.mimeType, sendSize = exported.sizeBytes
        let jpeg = exported.path + ".jpg"
        defer { try? FileManager.default.removeItem(atPath: jpeg) }
        if sendAs == .photo && Router.isHeic(file.displayName) {
            if let conv = converter, conv.toJpeg(source: exported.path, dest: jpeg, maxBytes: settings.botPhotoMaxBytes),
               let size = (try? FileManager.default.attributesOfItem(atPath: jpeg)[.size]) as? NSNumber, size.int64Value > 0 {
                sendPath = jpeg; sendMime = "image/jpeg"; sendSize = size.int64Value
                sendName = ((file.displayName as NSString).deletingPathExtension) + ".jpg"
            } else {
                sendAs = .document   // cannot convert: the original goes as a file, nothing is lost
            }
        }
        let job = SendJob(chatId: settings.chatId!, threadId: file.topicId ?? rule.topicId, path: sendPath, displayName: sendName,
                          mimeType: sendMime, sendAs: sendAs,
                          caption: Caption.build(displayName: file.displayName, takenAt: file.takenAt, ruleName: rule.name, sha256: hash),
                          sizeBytes: sendSize, width: file.width, height: file.height, durationMs: file.durationMs)
        let name = file.displayName
        if file.partCount > 1 { return await sendInParts(file, rule, exported: exported, hash: hash, job: job) }
        let route = file.route ?? .bot
        if route == .bot, let bg = background { return handOff(file, job: job, hash: hash, bg) }
        guard let chosen = route == .account ? account : sender else {
            _ = try? store.apply(file.id, .networkStop, now: clock.now())
            if route == .account { accountStopped = true } else { botStopped = true }
            return .retry
        }
        let result = await chosen.send(job) { [weak self] s, t in self?.progress?.fileProgress(name: name, done: s, total: t) }
        return complete(file.id, result, job: job, hash: hash)
    }

    /// Gives one upload to the system. The file stays `uploading`; `completeBackground` records Telegram's answer, even if the app was asleep.
    func handOff(_ file: FileRecord, job: SendJob, hash: String, _ bg: BackgroundUploading) -> Step {
        let out = store.bgOutstanding()
        if out.count >= handoffMaxFiles || out.bytes + job.sizeBytes > handoffMaxBytes {
            _ = try? store.apply(file.id, .networkStop, now: clock.now()); handoffFull = true; return .retry
        }
        let now = clock.now()
        store.putBgJob(BgJobRecord(fileId: file.id, hash: hash, json: BgJobCodec.encode(job), bodyPath: "", bytes: job.sizeBytes, createdAt: now))
        guard let body = bg.submit(job, fileId: file.id) else {
            store.removeBgJob(file.id); _ = try? store.apply(file.id, .networkStop, now: clock.now()); botStopped = true; return .networkFail
        }
        var rec = store.bgJob(file.id)!; rec.bodyPath = body; store.putBgJob(rec)
        return .done
    }

    /// Telegram answered (or the connection failed) for an upload the system carried out in the background.
    public func completeBackground(fileId: Int64, httpCode: Int, data: Data, error: Error?) {
        guard let rec = store.bgJob(fileId) else { return }
        defer { store.removeBgJob(fileId); if !rec.bodyPath.isEmpty { try? FileManager.default.removeItem(atPath: rec.bodyPath) } }
        guard let file = store.file(id: fileId), file.state == .uploading, let job = BgJobCodec.decode(rec.json) else { return }
        let result: SendResult
        if error != nil && data.isEmpty { result = .failed(.network) }
        else {
            switch BotApi.parse(httpCode: httpCode, data: data, { BotApi.parseSent($0, kind: job.sendAs, fallbackChat: job.chatId) }) {
            case .ok(let m): result = .sent(m)
            case .err(let e): result = .failed(e)
            }
        }
        complete(fileId, result, job: job, hash: rec.hash)
    }

    /// Pause or delay: stop what the system is sending and queue those files again, so Pause really stops uploading.
    public func cancelBackground() {
        guard let bg = background else { return }
        bg.cancelAll()
        for j in store.bgJobs() {
            if let f = store.file(id: j.fileId), f.state == .uploading { _ = try? store.apply(f.id, .recoverAfterCrash, now: clock.now()) }
            store.removeBgJob(j.fileId); if !j.bodyPath.isEmpty { try? FileManager.default.removeItem(atPath: j.bodyPath) }
        }
    }

    /// A background upload the system no longer knows about (app reinstalled, task lost): put the file back in the queue.
    func reconcileBackground() async {
        guard let bg = background else { return }
        let jobs = store.bgJobs(); if jobs.isEmpty { return }
        let active = await bg.activeFileIds()
        for j in jobs where !active.contains(j.fileId) && clock.now() - j.createdAt > 15 * Time.minute {
            if let f = store.file(id: j.fileId), f.state == .uploading { _ = try? store.apply(f.id, .recoverAfterCrash, now: clock.now()) }
            store.removeBgJob(j.fileId); if !j.bodyPath.isEmpty { try? FileManager.default.removeItem(atPath: j.bodyPath) }
        }
    }

    /// A video over 2 GB: cut at keyframes, the parts go up together as one album and are never deleted by the app.
    func sendInParts(_ file: FileRecord, _ rule: Rule, exported: ExportedFile, hash: String, job base: SendJob) async -> Step {
        func fail(_ why: String) -> Step { handleFailure(file, rule, .badRequest(why)) }
        guard let sender = account else {
            _ = try? store.apply(file.id, .networkStop, now: clock.now()); accountStopped = true; return .retry
        }
        guard let cutter = splitter, let dir = scratchDir else { return fail("cutting a big video into parts is not available") }
        let outDir = dir + "/split-\(file.id)"
        defer { try? FileManager.default.removeItem(atPath: outDir) }
        let name = file.displayName
        let cut = await cutter.split(source: exported.path, maxPartBytes: SplitPlan.partMaxBytes, outDir: outDir) { [weak self] d, t in
            self?.progress?.fileProgress(name: "\(name) (cutting)", done: d, total: t)
        }
        if Task.isCancelled { _ = try? store.apply(file.id, .networkStop, now: clock.now()); return .retry }
        guard case .parts(let paths) = cut else { if case .failed(let r) = cut { return fail("it could not be cut into parts: \(r)") }; return fail("it could not be cut") }
        let n = paths.count
        let jobs: [SendJob] = paths.enumerated().map { i, p in
            let pn = SplitPlan.partName(file.displayName, index: i, parts: n)
            let size = ((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value ?? 0
            return SendJob(chatId: base.chatId, threadId: base.threadId, path: p, displayName: pn, mimeType: "video/mp4", sendAs: file.sendAs ?? .video,
                           caption: Caption.build(displayName: pn, takenAt: file.takenAt, ruleName: rule.name, sha256: hash), sizeBytes: size,
                           width: file.width, height: file.height, durationMs: nil)
        }
        progress?.fileStarted(name: "\(file.displayName) (\(n) parts)", bytesTotal: file.sizeBytes, filesDone: 0, filesTotal: 0)
        await pacer.awaitSlot(.account)
        let label = "\(file.displayName) (\(n) parts)"
        let result = await sender.sendAlbum(jobs) { [weak self] s, t in self?.progress?.fileProgress(name: label, done: s, total: t) }
        switch result {
        case .failed(let e): return handleFailure(file, rule, e)
        case .unsupported: return fail("sending parts together is not available")
        case .sent(let msgs):
            guard msgs.count == n else { return fail("the album answer did not match its parts") }
            let bad = zip(jobs, msgs).compactMap { j, m -> String? in if case .mismatch(let r) = Verifier.checkReply(j, m) { return r }; return nil }.first
            let now = clock.now()
            guard var uploaded = try? store.apply(file.id, .sent(msgs[0], sha256: hash), now: now) else { return .retry }
            uploaded.partCount = n; store.updateDetails(uploaded)
            events.add(.uploaded, "\(file.displayName) uploaded in \(n) parts", ruleId: rule.id, fileId: file.id, bytes: file.sizeBytes)
            if let why = bad {
                _ = try? store.apply(file.id, .replyMismatch(why), now: clock.now(), maxAttempts: settings.maxAttempts, jitter: Double.random(in: 0...1))
                events.add(.verifyFailed, "\(file.displayName): Telegram reply did not match (\(why))", ruleId: rule.id, fileId: file.id)
            } else {
                _ = try? store.apply(file.id, .replyOk(deleteAfter: nil), now: clock.now())   // never deleted by the app: no delete date
                events.add(.verified, "\(file.displayName) checked in Telegram (\(n) parts)", ruleId: rule.id, fileId: file.id)
            }
            return .done
        }
    }

    /// Records what Telegram answered. Shared by the foreground loop and the background-session path.
    @discardableResult
    func complete(_ fileId: Int64, _ result: SendResult, job: SendJob, hash: String?) -> Step {
        guard let file = store.file(id: fileId), let rule = store.rule(id: file.ruleId) else { return .retry }
        switch result {
        case .sent(let msg):
            settings.botProblem = false
            settings.lastUploadAt = clock.now()   // per file, so "last upload" is right while a run (or the system) is still sending
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
