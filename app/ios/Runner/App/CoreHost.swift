import Foundation
import UIKit
import Photos
import TeleCore

private func bridgeEnum<T: CaseIterable>(_ raw: String, _ type: T.Type) -> T { T.allCases.first { "\($0)" == raw } ?? T.allCases.first! }
private func coreRaw<T>(_ e: T) -> String { "\(e)" }
private func fail(_ code: String, _ msg: String, _ details: String? = nil) -> PigeonError { PigeonError(code: code, message: msg, details: details) }

private extension TgError {
    var setupMessage: String {
        switch self {
        case .badToken: return "That token did not work. Copy it again from BotFather."
        case .network: return "No internet. Try again when online."
        case .floodWait(let s): return "Telegram says wait \(s) seconds, then try again."
        case .forbidden: return "The bot is not allowed to do that in the group. Make it an admin."
        case .topicMissing: return "That topic is gone in Telegram."
        default: return userMessage
        }
    }
    func thrown() -> PigeonError {
        switch self {
        case .network: return fail("NO_NETWORK", setupMessage)
        case .floodWait(let s): return fail("FLOOD_WAIT", setupMessage, String(s))
        default: return fail("TELEGRAM", setupMessage)
        }
    }
}

/// What the Flutter screens can ask of the core. Thin on purpose: every rule lives in TeleCore.
final class CoreHost: CoreHostApi {
    private var rt: Runtime { Runtime.shared }
    private var lastChecks: [Int64: GroupCheck] = [:]

    // MARK: conversions
    private func toBridge(_ r: CRule) -> Rule {
        Rule(id: r.id, name: r.name, folderPath: r.folderPath, includeSubfolders: r.includeSubfolders, mediaTypes: bridgeEnum(r.mediaTypes.rawValue, MediaTypes.self),
             topicId: r.topicId, newTopicName: nil, uploadAs: bridgeEnum(r.uploadAs.rawValue, UploadAs.self), mode: bridgeEnum(r.mode.rawValue, RuleMode.self),
             retentionDays: Int64(r.retentionDays), startMode: bridgeEnum(r.startMode.rawValue, StartMode.self), startDate: r.startDate, enabled: r.enabled,
             dryRun: r.dryRun, deleteWarningAccepted: r.deleteWarningAcceptedAt != nil, sortDocuments: r.sortDocuments)
    }
    private func toCore(_ r: Rule, existing: CRule?, topicId: Int64?) -> CRule {
        var c = CRule(name: r.name, folderPath: r.folderPath)
        c.id = existing?.id ?? 0; c.includeSubfolders = r.includeSubfolders
        c.mediaTypes = TeleCore.MediaTypes(rawValue: coreRaw(r.mediaTypes)) ?? .both; c.topicId = topicId
        c.uploadAs = TeleCore.UploadAs(rawValue: coreRaw(r.uploadAs)) ?? .media; c.mode = TeleCore.RuleMode(rawValue: coreRaw(r.mode)) ?? .uploadOnly
        c.retentionDays = Int(r.retentionDays); c.startMode = TeleCore.StartMode(rawValue: coreRaw(r.startMode)) ?? .today; c.startDate = r.startDate
        c.enabled = r.enabled; c.dryRun = r.dryRun
        c.deleteWarningAcceptedAt = r.deleteWarningAccepted ? (existing?.deleteWarningAcceptedAt ?? rt.clock.now()) : nil
        c.deletedAt = existing?.deletedAt; c.createdAt = existing?.createdAt ?? rt.clock.now(); c.updatedAt = rt.clock.now(); c.sortDocuments = r.sortDocuments
        return c
    }
    private func toBridge(_ t: TopicRecord) -> Topic { Topic(threadId: t.threadId, name: t.name, missing: t.missing, madeByApp: t.madeByApp) }
    private func link(_ f: CFileRecord) -> String? {
        guard let chat = f.tgChatId ?? rt.settings.chatId, let msg = f.tgMessageId else { return nil }
        let s = String(chat); guard s.hasPrefix("-100") else { return nil }
        let internalId = String(s.dropFirst(4))
        if let th = f.tgThreadId { return "https://t.me/c/\(internalId)/\(th)/\(msg)" }
        return "https://t.me/c/\(internalId)/\(msg)"
    }
    private func toBridge(_ f: CFileRecord, ruleName: String) -> FileItem {
        FileItem(id: f.id, ruleId: f.ruleId, ruleName: ruleName, displayName: f.displayName, path: f.path, sizeBytes: f.sizeBytes,
                 state: bridgeEnum(f.state.rawValue, FileState.self), takenAt: f.takenAt, width: f.width.map(Int64.init), height: f.height.map(Int64.init),
                 durationMs: f.durationMs, sendAs: f.sendAs?.rawValue.uppercased(), shortHash: f.sha256.map { String($0.prefix(12)) }, telegramLink: link(f),
                 queuedAt: f.queuedAt > 0 ? f.queuedAt : nil, uploadedAt: f.uploadedAt, verifiedAt: f.verifiedAt, deleteAfter: f.deleteAfter,
                 deletedAt: f.deletedAt, lastError: f.lastError, attempts: Int64(f.attempts))
    }
    private func items(_ fs: [CFileRecord]) -> [FileItem] {
        var names: [Int64: String] = [:]
        return fs.map { f in toBridge(f, ruleName: names[f.ruleId] ?? { let n = rt.store.rule(id: f.ruleId)?.name ?? ""; names[f.ruleId] = n; return n }()) }
    }
    private func stats(_ r: CRule) -> RuleStats {
        let counts = rt.store.stateCounts().filter { $0.ruleId == r.id }
        func n(_ s: [TeleCore.FileState]) -> Int64 { Int64(counts.filter { s.contains($0.state) }.reduce(0) { $0 + $1.count }) }
        func b(_ s: [TeleCore.FileState]) -> Int64 { counts.filter { s.contains($0.state) }.reduce(0) { $0 + $1.bytes } }
        let due = Int64(rt.store.verifiedDue(ruleId: r.id, now: rt.clock.now(), limit: 100_000).count)
        let missing = r.topicId.flatMap { rt.store.topic(threadId: $0)?.missing } ?? false
        return RuleStats(ruleId: r.id, queued: n([.queued, .failed, .uploading]), backedUp: n([.verified, .uploaded]), backedUpBytes: b([.verified, .uploaded]),
                         waitingDelete: due, deleted: n([.deleted]), freedBytes: b([.deleted]), skipped: n([.skipped]),
                         deleteBlockedReason: rt.settings.deletesBlockedReason, topicMissing: missing)
    }
    private func tok() -> String? { Keychain.get("bot.token") }

    // MARK: status and controls
    func getStatus() async throws -> Status { await rt.buildStatus() }
    func pause() async throws { await MainActor.run { rt.pauseNow() } }
    func resume() async throws { await MainActor.run { rt.resumeNow() } }
    func delay(minutes: Int64) async throws { await MainActor.run { rt.delayNow(minutes: Int(minutes)) } }
    func scanNow(ruleId: Int64?) async throws { rt.startRun(scan: true) }
    func uploadNow(mobileDataOnce: Bool) async throws { if mobileDataOnce { rt.settings.mobileOnceUntilEmpty = true }; rt.startRun(scan: false) }

    // MARK: rules
    func listRules() async throws -> [RuleWithStats] { rt.rules.active().map { RuleWithStats(rule: toBridge($0), stats: stats($0)) } }
    func getRule(id: Int64) async throws -> RuleWithStats {
        guard let r = rt.rules.get(id) else { throw fail("VALIDATION", "That rule is gone.") }
        return RuleWithStats(rule: toBridge(r), stats: stats(r))
    }
    func saveRule(rule: Rule) async throws -> Int64 {
        let existing = rule.id.flatMap { rt.rules.get($0) }
        var topicId = rule.topicId
        if let name = rule.newTopicName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            guard tok() != nil, rt.settings.chatId != nil else { throw fail("NOT_SET_UP", "Topics can be made once Telegram is connected.") }
            topicId = try await createTopic(name).threadId
        }
        let core = toCore(rule, existing: existing, topicId: topicId)
        do {
            let saved = try rt.rules.save(core, folderExists: rt.source.albumExists(core.folderPath))
            rt.startRun()
            return saved.id
        } catch let e as RuleException { throw fail("VALIDATION", e.problems.first?.message ?? "Check the rule.", e.problems.first?.field) }
    }
    func setRuleEnabled(id: Int64, enabled: Bool) async throws { rt.rules.setEnabled(id, enabled) }
    func deleteRule(id: Int64) async throws { rt.rules.softDelete(id) }
    func previewRule(rule: Rule) async throws -> Runner.BacklogPreview {
        var c = toCore(rule, existing: nil, topicId: rule.topicId)
        switch c.startMode { case .today: c.startDate = rt.clock.now(); case .sinceDate: break; case .everything: c.startDate = nil }
        let p = rt.scanner.preview(c)
        return Runner.BacklogPreview(count: Int64(p.count), bytes: p.bytes, newestAt: p.newestAt, oldestAt: p.oldestAt)
    }

    private struct Suggestion { let id: String; let label: String; let album: String; let types: TeleCore.MediaTypes; let original: Bool }
    private func suggestions() -> [Suggestion] {
        var s = [Suggestion(id: "sugg:photos", label: "Gallery photos", album: "smart:recents", types: .photos, original: true),
                 Suggestion(id: "sugg:videos", label: "Gallery videos", album: "smart:recents", types: .videos, original: true),
                 Suggestion(id: "sugg:screens", label: "Screenshots", album: "smart:screenshots", types: .both, original: false)]
        for a in rt.source.userAlbums() where a.title.lowercased().contains("whatsapp") {
            s.append(Suggestion(id: "sugg:wa:" + a.id, label: a.title, album: a.id, types: .both, original: false))
        }
        return s
    }
    func suggestedFolders() async throws -> [FolderInfo] {
        let used = Dictionary(rt.rules.active().map { ($0.folderPath, $0.name) }, uniquingKeysWith: { a, _ in a })
        return suggestions().compactMap { s in
            let n = rt.source.count(s.album, s.types)
            guard n > 0 || s.album.hasPrefix("smart:") else { return nil }
            return FolderInfo(path: s.id, label: s.label, mediaCount: Int64(n), usedByRule: used[s.album], isSuggestion: true, hint: nil)
        }
    }
    func listFolder(path: String) async throws -> [FolderInfo] {
        guard path.isEmpty else { return [] }
        let used = Dictionary(rt.rules.active().map { ($0.folderPath, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out = PhotoLibrarySource.smart.map { FolderInfo(path: $0.id, label: $0.label, mediaCount: Int64(rt.source.count($0.id)), usedByRule: used[$0.id], isSuggestion: false, hint: nil) }
        out += rt.source.userAlbums().map { FolderInfo(path: $0.id, label: $0.title, mediaCount: Int64($0.count), usedByRule: used[$0.id], isSuggestion: false, hint: nil) }
        return out.filter { $0.mediaCount > 0 }
    }
    func listTopics() async throws -> [Topic] { rt.settings.chatId.map { rt.store.topics(chatId: $0).map(toBridge) } ?? [] }
    func remakeTopic(ruleId: Int64) async throws -> Topic {
        guard var r = rt.rules.get(ruleId) else { throw fail("VALIDATION", "That rule is gone.") }
        let t = try await createTopic(r.name)
        if let old = r.topicId { rt.store.markMissing(threadId: old, true) }
        r.topicId = t.threadId; r.updatedAt = rt.clock.now(); rt.store.update(rule: r); rt.startRun(scan: false)
        return toBridge(t)
    }
    func stopAllDeletes() async throws { rt.rules.stopAllDeletes(); rt.pushStatus() }

    @discardableResult
    private func createTopic(_ name: String) async throws -> TopicRecord {
        guard let chat = rt.settings.chatId else { throw fail("NOT_SET_UP", "Choose a group first.") }
        switch await rt.api.createForumTopic(chat: chat, name: name) {
        case .ok(let t):
            var rec = TopicRecord(threadId: t.threadId, chatId: chat, name: t.name); rec.createdAt = rt.clock.now(); rt.store.upsert(topic: rec); return rec
        case .err(.chatMigrated(let new)): rt.settings.chatId = new; return try await createTopic(name)
        case .err(let e): throw e.thrown()
        }
    }

    // MARK: reviews
    private func review(_ rv: ReviewRecord, files: [CFileRecord], preview: Bool) -> Review {
        Review(id: rv.id, ruleId: rv.ruleId, ruleName: rt.store.rule(id: rv.ruleId)?.name ?? "", fileCount: Int64(rv.fileCount), totalBytes: rv.totalBytes, files: items(files), preview: preview)
    }
    func getReview(ruleId: Int64) async throws -> Review? {
        rt.cleaner.prepareReviews()
        guard let rv = rt.store.waitingReview(ruleId: ruleId) else { return nil }
        return review(rv, files: Array(rt.store.inReview(rv.id).prefix(500)), preview: false)
    }
    func previewDeletes(ruleId: Int64) async throws -> Review {
        guard let r = rt.rules.get(ruleId) else { throw fail("VALIDATION", "That rule is gone.") }
        let files = rt.store.verifiedDue(ruleId: ruleId, now: rt.clock.now(), limit: 500)
        return Review(id: 0, ruleId: ruleId, ruleName: r.name, fileCount: Int64(files.count), totalBytes: files.reduce(0) { $0 + $1.sizeBytes }, files: items(files), preview: true)
    }
    /// Approving raises the iPhone's own "Delete N photos?" prompt. Nothing is deleted unless the person taps Delete there.
    func approveReview(reviewId: Int64) async throws {
        rt.cleaner.approve(reviewId)
        rt.tracker.cleaning = true; rt.pushStatus()
        let out = await rt.cleaner.deleteApproved(reviewId: reviewId)
        rt.tracker.cleaning = false
        if out.declined, var rv = rt.store.review(id: reviewId) { rv.status = .waiting; rv.decidedAt = nil; rt.store.update(review: rv) }   // keep it for later
        rt.pushStatus()
        try? await rt.events_?.onHistoryChanged()
    }
    func dismissReview(reviewId: Int64) async throws { rt.cleaner.dismiss(reviewId); rt.pushStatus() }

    // MARK: files and history
    func listEvents(filter: HistoryFilter, search: String?, ruleId: Int64?, cursor: Int64?) async throws -> EventPage {
        let kinds: Set<EventKind>?
        switch filter {
        case .all: kinds = nil
        case .uploaded: kinds = [.uploaded, .verified]
        case .deleted: kinds = [.deleted, .reviewApproved]
        case .skipped: kinds = [.skipped]
        case .problems: kinds = [.failed, .verifyFailed, .skipped, .deleteDenied, .loginExpired, .permissionLost, .topicMissing, .botProblem, .retried]
        }
        let rows = rt.store.events(kinds: kinds, ruleId: ruleId, search: search, beforeId: cursor, limit: 50)
        return EventPage(items: rows.map { EventItem(id: $0.id, at: $0.at, kind: $0.kind.rawValue.reduce("") { $1.isUppercase ? $0 + "_" + String($1) : $0 + String($1).uppercased() }, message: $0.message, fileId: $0.fileId, ruleId: $0.ruleId, bytes: $0.bytes) },
                         nextCursor: rows.count == 50 ? rows.last?.id : nil)
    }
    func listFiles(ruleId: Int64, state: FileState?, cursor: Int64?) async throws -> FilePage {
        let rows = rt.store.page(ruleId: ruleId, state: state.flatMap { TeleCore.FileState(rawValue: coreRaw($0)) }, cursor: cursor, limit: 50)
        return FilePage(items: items(rows), nextCursor: rows.count == 50 ? rows.last?.id : nil)
    }
    func getFile(id: Int64) async throws -> FileItem {
        guard let f = rt.store.file(id: id) else { throw fail("VALIDATION", "That file is gone.") }
        return items([f])[0]
    }
    func retryFile(id: Int64) async throws {
        _ = try? rt.store.apply(id, .retryByPerson, now: rt.clock.now())
        rt.events.add(.retried, "Put back in the queue by you", fileId: id); rt.startRun(scan: false)
    }

    // MARK: settings
    func getSettings() async throws -> AppSettings {
        let s = rt.settings
        return AppSettings(groupByDay: s.groupByDay, documentsTopicId: s.documentsTopicId, allowMobileData: s.allowMobileData,
                           delayOptionsMinutes: s.delayOptionsMinutes.map(Int64.init), defaultRetentionDays: Int64(s.defaultRetentionDays),
                           setupDone: s.setupDone, setupStep: s.setupStep, debugBuild: s.debugBuild)
    }
    func setAllowMobileData(on: Bool) async throws { rt.settings.allowMobileData = on; if on { rt.startRun(scan: false) } }
    func setGroupByDay(on: Bool) async throws { rt.settings.groupByDay = on }
    func setDocumentsTopic(topicId: Int64?) async throws { rt.settings.documentsTopicId = topicId }
    func createDocumentsTopic() async throws -> Int64 {
        guard tok() != nil, let chat = rt.settings.chatId else { throw fail("NOT_SET_UP", "Topics can be made once Telegram is connected.") }
        var id = rt.store.topics(chatId: chat).first(where: { $0.name == "Documents" && !$0.missing })?.threadId
        if id == nil { id = try await createTopic("Documents").threadId }
        let docId = id!
        rt.settings.documentsTopicId = docId; return docId
    }
    func setDelayOptions(minutes: [Int64]) async throws {
        let m = minutes.map(Int.init)
        guard Settings.isValidDelayOptions(m) else { throw fail("VALIDATION", "Use 1 to 4 options, each between 15 minutes and 24 hours.") }
        rt.settings.delayOptionsMinutes = m; Notifier.shared.registerCategories()
    }
    func setDefaultRetention(days: Int64) async throws {
        guard (1...365).contains(days) else { throw fail("VALIDATION", "Use 1 to 365 days.") }
        rt.settings.defaultRetentionDays = Int(days)
    }
    func setSetupStep(step: String) async throws { rt.settings.setupStep = step }
    func finishSetup() async throws { rt.settings.setupDoneAt = rt.clock.now(); BackgroundWork.schedule(); rt.startRun()
        _ = await Notifier.shared.requestAuthorization() }
    func exportRules() async throws -> String {
        let names = rt.settings.chatId.map { c in Dictionary(rt.store.topics(chatId: c).map { ($0.threadId, $0.name) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
        let arr: [[String: Any]] = rt.rules.active().map { r in
            ["name": r.name, "folderPath": r.folderPath, "mediaTypes": r.mediaTypes.rawValue, "topicName": r.topicId.flatMap { names[$0] } ?? "",
             "uploadAs": r.uploadAs.rawValue, "retentionDays": r.retentionDays, "startMode": r.startMode.rawValue, "sortDocuments": r.sortDocuments]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "rules": arr], options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    func importRules(json: String) async throws -> Int64 {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let arr = root["rules"] as? [[String: Any]] else {
            throw fail("VALIDATION", "That file did not work.")
        }
        let topics = rt.settings.chatId.map { c in Dictionary(rt.store.topics(chatId: c).map { ($0.name.lowercased(), $0.threadId) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
        var n: Int64 = 0
        for o in arr {
            guard let name = o["name"] as? String, let folder = o["folderPath"] as? String else { continue }
            var r = CRule(name: name, folderPath: folder)
            r.mediaTypes = (o["mediaTypes"] as? String).flatMap(TeleCore.MediaTypes.init) ?? .both
            r.uploadAs = (o["uploadAs"] as? String).flatMap(TeleCore.UploadAs.init) ?? .media
            r.retentionDays = o["retentionDays"] as? Int ?? rt.settings.defaultRetentionDays
            r.startMode = (o["startMode"] as? String).flatMap(TeleCore.StartMode.init) ?? .today
            r.topicId = (o["topicName"] as? String).flatMap { topics[$0.lowercased()] }
            if (try? rt.rules.save(r, folderExists: rt.source.albumExists(folder))) != nil { n += 1 }
        }
        return n
    }

    // MARK: telegram
    func setBotToken(token: String) async throws -> BotInfo {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = BotApi(tokenProvider: { t }, transport: URLSessionTransport())
        switch await probe.getMe() {
        case .ok(let u): Keychain.put("bot.token", t); rt.settings.botId = u.id; rt.settings.botUsername = u.username; return BotInfo(id: u.id, username: u.username, name: u.name)
        case .err(let e): throw e.thrown()
        }
    }
    func findGroups() async throws -> [GroupCandidate] {
        switch await rt.api.getUpdates() { case .ok(let g): return g.map { GroupCandidate(chatId: $0.id, title: $0.title) }; case .err(let e): throw e.thrown() }
    }
    private func check(_ chatId: Int64) async throws -> GroupCheck {
        guard let botId = rt.settings.botId else { throw TgError.badToken.thrown() }
        var id = chatId
        var chat = await rt.api.getChat(id)
        if case .err(.chatMigrated(let new)) = chat { id = new; chat = await rt.api.getChat(id) }
        guard case .ok(let info) = chat else { throw chat.error!.thrown() }
        let m = (await rt.api.getChatMember(info.id, user: botId)).value ?? MemberInfo(status: "", canManageTopics: false)
        let admin = m.status == "administrator" || m.status == "creator"
        let c = GroupCheck(chatId: info.id, title: info.title, topicsOn: info.isForum, botIsAdmin: admin, botCanManageTopics: admin && m.canManageTopics)
        lastChecks[c.chatId] = c; return c
    }
    func checkGroup(chatId: Int64) async throws -> GroupCheck { try await check(chatId) }
    func selectGroup(chatId: Int64) async throws {
        let c = try await check(chatId)
        guard c.topicsOn && c.botIsAdmin && c.botCanManageTopics else { throw fail("TELEGRAM", "The group is not ready yet. Check Topics and the bot's rights.") }
        switch await rt.api.sendMessage(chat: c.chatId, text: "teleBackup is connected. Each album you back up gets its own topic here.") {
        case .ok: rt.settings.chatId = c.chatId; rt.settings.chatTitle = c.title
        case .err(let e): throw e.thrown()
        }
    }
    func getTelegramState() async throws -> TelegramState {
        var st = rt.telegramState()
        if let g = st.group, let c = lastChecks[g.chatId] { st.group = c }
        return st
    }
    func accountStart(apiId: Int64, apiHash: String) async throws {
        let r = await rt.accountAuth.start(apiId: apiId, apiHash: apiHash)
        rt.pushTelegramState()
        if let e = r.lastError, r.step == .none || r.step == .waitParams { throw fail("VALIDATION", e) }
    }
    func accountPhone(phone: String) async throws { let r = await rt.accountAuth.phone(phone); rt.pushTelegramState(); if let e = r.lastError, r.step == .waitPhone || r.step == .expired { throw fail("VALIDATION", e) } }
    func accountCode(code: String) async throws { let r = await rt.accountAuth.code(code); rt.pushTelegramState(); if let e = r.lastError, r.step == .waitCode { throw fail("VALIDATION", e) }; rt.startRun(scan: false) }
    func accountPassword(password: String) async throws { let r = await rt.accountAuth.password(password); rt.pushTelegramState(); if let e = r.lastError, r.step == .waitPassword { throw fail("VALIDATION", e) }; rt.startRun(scan: false) }
    func accountResendCode() async throws { _ = await rt.accountAuth.resendCode(); rt.pushTelegramState() }
    func accountLogout() async throws { await rt.accountAuth.logout(); rt.pushTelegramState(); rt.pushStatus() }

    func createSuggestedRules(suggestionPaths: [String], startMode: StartMode, startDate: Int64?) async throws -> Int64 {
        guard tok() != nil, rt.settings.chatId != nil else { throw fail("NOT_SET_UP", "Connect Telegram first.") }
        var made: Int64 = 0
        for id in suggestionPaths {
            guard let s = suggestions().first(where: { $0.id == id }) else { continue }
            let topic = try await createTopic(s.label)
            var base = s.label; var n = 2; let used = Set(rt.rules.active().map { $0.name.lowercased() })
            while used.contains(base.lowercased()) { base = "\(s.label) (\(n))"; n += 1 }
            var r = CRule(name: base, folderPath: s.album)
            r.mediaTypes = s.types; r.topicId = topic.threadId; r.uploadAs = s.original ? .original : .media; r.mode = .uploadOnly
            r.retentionDays = rt.settings.defaultRetentionDays; r.startMode = TeleCore.StartMode(rawValue: coreRaw(startMode)) ?? .today; r.startDate = startDate
            r.enabled = true; r.dryRun = true
            try rt.rules.save(r); made += 1
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // Telegram limits how fast a bot may make topics
        }
        rt.startRun()
        return made
    }

    // MARK: phone
    func getPermissions() async throws -> Permissions {
        let p = await rt.permissionState()
        return Permissions(notifications: p.notifications, allFiles: p.photos, batteryExempt: p.backgroundRefresh, mediaRead: p.photos, makerGuide: nil)
    }
    /// "Photos": ask the first time, then send the person to Settings.
    func openAllFilesSettings() async throws {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite); rt.pushStatus(); return }
        await Self.openSettings()
    }
    func requestBatteryExemption() async throws { await Self.openSettings() }   // Background App Refresh lives in the app's Settings page
    func openNotificationSettings() async throws {
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined { _ = await Notifier.shared.requestAuthorization(); rt.pushStatus(); return }
        await Self.openSettings()
    }
    @MainActor static func openSettings() { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }

    // MARK: help
    func diagnostics() async throws -> String {
        let s = rt.settings; let p = await rt.permissionState()
        let info = Bundle.main.infoDictionary
        let counts = Dictionary(grouping: rt.store.stateCounts(), by: { $0.state.rawValue }).map { "\($0.key): \($0.value.reduce(0) { $0 + $1.count })" }.sorted().joined(separator: ", ")
        let problems = rt.store.events(kinds: [.failed, .verifyFailed, .skipped, .deleteDenied, .topicMissing, .botProblem], ruleId: nil, search: nil, beforeId: nil, limit: 30)
        func d(_ t: Int64?) -> String { t.map { Date(timeIntervalSince1970: Double($0) / 1000).description } ?? "never" }
        return """
        teleBackup \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) on iPhone, iOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model))
        setup done: \(s.setupDone)  control: \(s.controlState.rawValue)
        photos: \(p.photos)  notifications: \(p.notifications)  background refresh: \(p.backgroundRefresh)
        last scan: \(d(s.lastScanAt))  last upload: \(d(s.lastUploadAt))  last clean: \(d(s.lastCleanAt))  last stop: \(s.lastStopReason ?? "-")
        files: \(counts.isEmpty ? "none" : counts)
        deletes blocked: \(s.deletesBlockedReason ?? "no")
        recent problems:
        \(problems.map { "- \($0.kind.rawValue): \($0.message)" }.joined(separator: "\n"))
        """
    }

    func devCommand(command: String, argument: String?) async throws -> String {
        guard rt.settings.debugBuild else { throw fail("INTERNAL", "Not available.") }
        switch command {
        case "timeWarp": rt.settings.timeWarp = argument == "on"; return "Time warp \(rt.settings.timeWarp ? "on" : "off")"
        case "scan", "upload": rt.startRun(scan: command == "scan"); return "Run started"
        case "clean": return "Ready to delete: \(rt.cleaner.prepareReviews()) new review(s)"
        case "wipe": rt.store.clearAll(); Keychain.put("bot.token", nil); return "Wiped"
        default: throw fail("VALIDATION", "Unknown command")
        }
    }
}
