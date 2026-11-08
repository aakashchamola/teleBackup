import XCTest
@testable import TeleCore

final class FakeGateway: TdGateway {
    var auth: TdAuth = .closed { didSet { onAuth?(auth) } }
    var onAuth: ((TdAuth) -> Void)?
    var phoneStep: TdStep = .ok, codeStep: TdStep = .ok
    var opened = 0, sent: [SendJob] = [], fetchAnswer: TdFetch = .unavailable, sendResult: SendResult?
    func open(_ p: TdParams) async { opened += 1; auth = .waitPhone }
    func submitPhone(_ p: String) async -> TdStep { if phoneStep == .ok { auth = .waitCode(sentTo: "SMS") }; return phoneStep }
    func submitCode(_ c: String) async -> TdStep { if codeStep == .ok { auth = .ready(name: "Test", phoneMasked: "+•• ••••• ••210") }; return codeStep }
    func submitPassword(_ p: String) async -> TdStep { .ok }
    func resendCode() async -> TdStep { .ok }
    func send(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> SendResult {
        sent.append(job)
        return sendResult ?? .sent(SentMessage(chatId: job.chatId, threadId: job.threadId, messageId: 500, fileUniqueId: "u", size: job.sizeBytes, width: job.width, height: job.height, durationMs: job.durationMs, kind: job.sendAs))
    }
    var albums: [[SendJob]] = [], albumFail: TgError?
    func sendAlbum(_ jobs: [SendJob], progress: @escaping (Int64, Int64) -> Void) async -> AlbumResult {
        albums.append(jobs)
        if let e = albumFail { return .failed(e) }
        return .sent(jobs.enumerated().map { i, j in SentMessage(chatId: j.chatId, threadId: j.threadId, messageId: Int64(900 + i), fileUniqueId: "u\(i)", size: j.sizeBytes, width: j.width, height: j.height, durationMs: nil, kind: j.sendAs) })
    }
    func fetch(chatId: Int64, botApiMessageId: Int64) async -> TdFetch { fetchAnswer }
    var pages: [TdHistory] = [], historyCalls = 0
    func history(chatId: Int64, fromTdlibId: Int64, limit: Int) async -> TdHistory { defer { historyCalls += 1 }; return historyCalls < pages.count ? pages[historyCalls] : TdHistory(captions: [], oldestId: nil) }
    func logOut() async { auth = .loggedOut }
    func close() { auth = .closed }
}
final class MemSecrets: SecretStore {
    var d: [String: String] = [:]
    func get(_ k: String) -> String? { d[k] }
    func put(_ k: String, _ v: String?) { d[k] = v }
}

final class AccountTests: XCTestCase {
    func makeAuth(_ g: FakeGateway, _ s: Settings) -> AccountAuth {
        AccountAuth(gateway: g, settings: s, secrets: MemSecrets(), folders: { ("/tmp/db", "/tmp/files") }, settleMs: 300)
    }
    func testLoginFlowReachesReadyAndSavesState() async throws {
        let s = Settings(try Store.inMemory()); let g = FakeGateway(); let a = makeAuth(g, s)
        var snap = await a.start(apiId: 1234, apiHash: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(snap.step, .waitPhone)
        snap = await a.phone("+91 98765 43210"); XCTAssertEqual(snap.step, .waitCode); XCTAssertEqual(snap.codeSentTo, "SMS")
        snap = await a.code("12345"); XCTAssertEqual(snap.step, .ready)
        XCTAssertEqual(s.accountState, .ready); XCTAssertEqual(s.accountName, "Test")
    }
    func testBadInputIsRejectedBeforeTelegram() async throws {
        let s = Settings(try Store.inMemory()); let g = FakeGateway(); let a = makeAuth(g, s)
        var snap = await a.start(apiId: 0, apiHash: "nope"); XCTAssertNotNil(snap.lastError); XCTAssertEqual(g.opened, 0)
        _ = await a.start(apiId: 1234, apiHash: "0123456789abcdef0123456789abcdef")
        snap = await a.phone("abc"); XCTAssertNotNil(snap.lastError)
    }
    func testRejectedCodeShowsPlainWords() async throws {
        let s = Settings(try Store.inMemory()); let g = FakeGateway(); g.codeStep = .rejected("That code is not right."); let a = makeAuth(g, s)
        _ = await a.start(apiId: 1234, apiHash: "0123456789abcdef0123456789abcdef"); _ = await a.phone("+919876543210")
        let snap = await a.code("1"); XCTAssertEqual(snap.lastError, "That code is not right.")
    }
    func testEnsureReadyExpiredSession() async throws {
        let s = Settings(try Store.inMemory()); s.accountState = .ready
        let g = FakeGateway(); let sec = MemSecrets(); sec.d = ["td.apiId": "1234", "td.apiHash": "0123456789abcdef0123456789abcdef"]
        let a = AccountAuth(gateway: g, settings: s, secrets: sec, folders: { ("/tmp/db", "/tmp/files") }, settleMs: 300)   // the saved session asks for a phone again = logged out elsewhere
        let r = await a.ensureReady(); XCTAssertEqual(r, .notLoggedIn); XCTAssertEqual(s.accountState, .expired)
    }
    func testRecheck() async throws {
        let s = Settings(try Store.inMemory()); s.accountState = .ready
        let g = FakeGateway(); g.auth = .ready(name: "T", phoneMasked: nil); let a = makeAuth(g, s); let rc = AccountRecheck(auth: a, gateway: g)
        var f = FileRecord(ruleId: 1, path: "p", displayName: "a.mov", mimeType: "video/quicktime", kind: .video, sizeBytes: 100, modifiedAt: 1, takenAt: 1)
        f.tgChatId = -100; f.tgMessageId = 7; f.tgSize = 100; f.tgFileUniqueId = "u"; f.sendAs = .video
        g.fetchAnswer = .found(SentMessage(chatId: -100, threadId: nil, messageId: 7, fileUniqueId: "u", size: 100, kind: .video))
        var c = await rc.recheck(f); XCTAssertEqual(c, .ok)
        g.fetchAnswer = .found(SentMessage(chatId: -100, threadId: nil, messageId: 7, fileUniqueId: "u", size: 99, kind: .video))
        c = await rc.recheck(f); XCTAssertEqual(c, .mismatch)
        g.fetchAnswer = .notFound; c = await rc.recheck(f); XCTAssertEqual(c, .notFound)
        g.fetchAnswer = .unavailable; c = await rc.recheck(f); XCTAssertEqual(c, .unavailable)
    }
    func testErrorMapping() {
        XCTAssertEqual(TdErrors.forSend(code: 429, message: "Too Many Requests: retry after 12"), .floodWait(seconds: 12))
        XCTAssertEqual(TdErrors.forSend(code: 401, message: "AUTH_KEY_UNREGISTERED"), .accountLoggedOut)
        XCTAssertEqual(TdErrors.forSend(code: 400, message: "TOPIC_DELETED"), .topicMissing)
        XCTAssertEqual(TdErrors.forSend(code: 400, message: "FILE_PARTS_INVALID"), .tooLarge)
        XCTAssertEqual(TdErrors.forSend(code: 502, message: "x"), .server(code: 502))
        XCTAssertEqual(TdIds.fromTdlib(TdIds.toTdlib(77)), 77)
        XCTAssertEqual(TdErrors.maskPhone("+919876543210"), "+•• ••••• ••210")
    }
}

final class BigVideoPipelineTests: XCTestCase {
    func testBigVideoGoesThroughAccountAndSmallOnesThroughBot() async throws {
        let store = try Store.inMemory(); let settings = Settings(store); let clock = FixedClock(10 * Time.day); let events = EventLog(store, clock)
        let rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        let control = ControlService(settings: settings, events: events, clock: clock)
        let src = FakeSource(); let ex = FakeExporter(src); let bot = FakeSender(); let g = FakeGateway(); g.auth = .ready(name: "T", phoneMasked: nil)
        settings.chatId = -100; settings.accountState = .ready
        let auth = AccountAuth(gateway: g, settings: settings, secrets: MemSecrets(), folders: { ("a", "b") }, settleMs: 200)
        let engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: Pacer(clock: clock, botPerMinute: 6000, burst: 100, accountMinGapMs: 0),
                                  exporter: ex, hasher: FakeHasher(), sender: bot, control: control, account: AccountSender(auth: auth, gateway: g))
        var r = Rule(name: "Videos", folderPath: "smart:videos"); r.topicId = 3; r.startMode = .everything; r.mediaTypes = .videos
        let rule = try rules.save(r)
        src.items = [MediaItem(path: "big", displayName: "big.MOV", mimeType: "video/quicktime", sizeBytes: 60_000_000, modifiedAt: 1, takenAt: 1, width: 1920, height: 1080, durationMs: 5000, kind: .video),
                     MediaItem(path: "small", displayName: "small.MOV", mimeType: "video/quicktime", sizeBytes: 2000, modifiedAt: 2, takenAt: 2, width: 1920, height: 1080, durationMs: 5000, kind: .video)]
        LibraryScanner(source: src, store: store, settings: settings, events: events, clock: clock).scan(rule)
        let out = await engine.run()
        XCTAssertEqual(out.filesDone, 2)
        XCTAssertEqual(g.sent.map { $0.displayName }, ["big.MOV"]); XCTAssertEqual(bot.sent.map { $0.displayName }, ["small.MOV"])
        XCTAssertEqual(store.page(ruleId: rule.id, state: .verified, cursor: nil, limit: 5).count, 2)
    }
    func testBigVideoWaitsWhenNoAccount() async throws {
        let store = try Store.inMemory(); let settings = Settings(store); let clock = FixedClock(10 * Time.day); let events = EventLog(store, clock)
        let rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        let src = FakeSource(); let engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: Pacer(clock: clock), exporter: FakeExporter(src), hasher: FakeHasher(), sender: FakeSender(), control: ControlService(settings: settings, events: events, clock: clock))
        settings.chatId = -100
        var r = Rule(name: "V", folderPath: "smart:videos"); r.startMode = .everything
        let rule = try rules.save(r)
        src.items = [MediaItem(path: "big", displayName: "big.MOV", mimeType: "video/quicktime", sizeBytes: 60_000_000, modifiedAt: 1, takenAt: 1, width: 1, height: 1, durationMs: 1, kind: .video)]
        LibraryScanner(source: src, store: store, settings: settings, events: events, clock: clock).scan(rule)
        let out = await engine.run(); XCTAssertEqual(out.reason, .nothingToSend); XCTAssertEqual(store.waitingAccountCount(), 1)
    }
}

struct FakeSplitter: VideoSplitter {
    var parts = 2, fail: String?
    func split(source: String, maxPartBytes: Int64, outDir: String, onProgress: @escaping (Int64, Int64) -> Void) async -> SplitResult {
        if let f = fail { return .failed(f) }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        return .parts((0..<parts).map { i in let p = outDir + "/p\(i).mp4"; try? Data(count: 10).write(to: URL(fileURLWithPath: p)); return p })
    }
}

final class SplitTests: XCTestCase {
    func testPlan() {
        XCTAssertEqual(SplitPlan.partsNeeded(2_100_000_000), 2); XCTAssertEqual(SplitPlan.partsNeeded(5_000_000_000), 3); XCTAssertEqual(SplitPlan.partsNeeded(100), 1)
        XCTAssertEqual(SplitPlan.partName("clip.MOV", index: 0, parts: 3), "clip (part 1 of 3).MOV")
        XCTAssertTrue(SplitPlan.canSplit("a.mov")); XCTAssertFalse(SplitPlan.canSplit("a.mkv"))
        XCTAssertLessThan(SplitPlan.targetPartBytes(4_000_000_000, parts: 3), SplitPlan.partMaxBytes)
    }
    func testRouterCutsBigVideosOnly() {
        XCTAssertEqual(Router.decide(sizeBytes: 3_000_000_000, kind: .video, uploadAs: .media, displayName: "a.MOV", width: 1, height: 1), .go(.account, .video, note: "cut into 2 parts", parts: 2))
        XCTAssertEqual(Router.decide(sizeBytes: 3_000_000_000, kind: .video, uploadAs: .original, displayName: "a.MOV", width: 1, height: 1), .go(.account, .document, note: "cut into 2 parts", parts: 2))
        XCTAssertEqual(Router.decide(sizeBytes: 3_000_000_000, kind: .video, uploadAs: .media, displayName: "a.mkv", width: 1, height: 1), .skip("Too big for Telegram (over 2 GB)"))
        XCTAssertEqual(Router.decide(sizeBytes: 3_000_000_000, kind: .photo, uploadAs: .media, displayName: "a.jpg", width: 1, height: 1), .skip("Too big for Telegram (over 2 GB)"))
        XCTAssertEqual(Router.decide(sizeBytes: 30_000_000_000, kind: .video, uploadAs: .media, displayName: "a.mov", width: 1, height: 1), .skip("Too big for Telegram (over 2 GB)"))   // needs more than 10 parts
    }

    func setup(splitter: VideoSplitter?) throws -> (Store, Settings, UploadEngine, FakeGateway, FakeSource, Rule, LibraryScanner, Cleaner, FixedClock) {
        let store = try Store.inMemory(); let settings = Settings(store); let clock = FixedClock(10 * Time.day); let events = EventLog(store, clock)
        let rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        let src = FakeSource(); let g = FakeGateway(); g.auth = .ready(name: "T", phoneMasked: nil)
        settings.chatId = -100; settings.accountState = .ready
        let auth = AccountAuth(gateway: g, settings: settings, secrets: MemSecrets(), folders: { ("a", "b") }, settleMs: 100)
        let ex = FakeExporter(src)
        let engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: Pacer(clock: clock, botPerMinute: 6000, burst: 100, accountMinGapMs: 0),
                                  exporter: ex, hasher: FakeHasher(), sender: FakeSender(), control: ControlService(settings: settings, events: events, clock: clock), account: AccountSender(auth: auth, gateway: g))
        engine.splitter = splitter; engine.scratchDir = NSTemporaryDirectory() + "split-test-\(UUID().uuidString)"
        var r = Rule(name: "Videos", folderPath: "smart:videos"); r.topicId = 3; r.startMode = .everything; r.mediaTypes = .videos
        r.mode = .uploadAndDelete; r.deleteWarningAcceptedAt = 1; r.dryRun = false
        let rule = try rules.save(r)
        return (store, settings, engine, g, src, rule, LibraryScanner(source: src, store: store, settings: settings, events: events, clock: clock),
                Cleaner(store: store, settings: settings, events: events, clock: clock, exporter: ex, deleter: FakeDeleter()), clock)
    }
    func hugeVideo(_ src: FakeSource) { src.items = [MediaItem(path: "huge", displayName: "huge.MOV", mimeType: "video/quicktime", sizeBytes: 100, modifiedAt: 1, takenAt: 1, width: 1920, height: 1080, durationMs: 60000, kind: .video)] }

    func testHugeVideoIsCutSentAsAlbumAndNeverDeleted() async throws {
        let (store, _, engine, g, src, rule, scanner, cleaner, clock) = try setup(splitter: FakeSplitter(parts: 3))
        hugeVideo(src)
        // the scanner decides from the size: make the row a 3-part video as a 5 GB file would be
        scanner.scan(rule)
        var f = try XCTUnwrap(store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 1).first)
        f.route = .account; f.sendAs = .video; f.partCount = 3; store.updateDetails(f)
        let out = await engine.run()
        XCTAssertEqual(out.filesDone, 1)
        XCTAssertEqual(g.albums.count, 1); XCTAssertEqual(g.albums[0].count, 3)
        XCTAssertEqual(g.albums[0].map { $0.displayName }, ["huge (part 1 of 3).MOV", "huge (part 2 of 3).MOV", "huge (part 3 of 3).MOV"])
        let done = try XCTUnwrap(store.file(id: f.id))
        XCTAssertEqual(done.state, .verified); XCTAssertEqual(done.partCount, 3); XCTAssertNil(done.deleteAfter)
        clock.t += 400 * Time.day
        XCTAssertEqual(cleaner.prepareReviews(), 0)   // a file sent in parts is never offered for delete
    }
    func testCutFailureIsRetriedNotLost() async throws {
        let (store, _, engine, g, src, rule, scanner, _, _) = try setup(splitter: FakeSplitter(fail: "no keyframes"))
        hugeVideo(src); scanner.scan(rule)
        var f = try XCTUnwrap(store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 1).first)
        f.route = .account; f.sendAs = .video; f.partCount = 2; store.updateDetails(f)
        _ = await engine.run()
        let after = try XCTUnwrap(store.file(id: f.id))
        XCTAssertTrue([.failed, .queued].contains(after.state)); XCTAssertEqual(after.attempts, 1); XCTAssertTrue(g.albums.isEmpty)
    }
    func testAlbumRefusalKeepsFileForLater() async throws {
        let (store, _, engine, g, src, rule, scanner, _, _) = try setup(splitter: FakeSplitter(parts: 2))
        g.albumFail = .floodWait(seconds: 60)
        hugeVideo(src); scanner.scan(rule)
        var f = try XCTUnwrap(store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 1).first)
        f.route = .account; f.sendAs = .video; f.partCount = 2; store.updateDetails(f)
        _ = await engine.run()
        XCTAssertEqual(store.file(id: f.id)?.state, .queued)
    }
}

final class RestoreTests: XCTestCase {
    func cap(_ name: String, _ takenAt: Int64, _ rule: String = "Camera Roll") -> String { Caption.build(displayName: name, takenAt: takenAt, ruleName: rule, sha256: "abcdef0123456789") }

    func testKeyIgnoresRuleNameAndHash() {
        let t: Int64 = 1_700_000_000_000
        XCTAssertEqual(Caption.key(caption: cap("IMG_1.HEIC", t, "A")), Caption.key(caption: cap("IMG_1.HEIC", t, "B")))
        XCTAssertEqual(Caption.key(caption: cap("IMG_1.HEIC", t)), Caption.key(displayName: "IMG_1.HEIC", takenAt: t))
        XCTAssertNil(Caption.key(caption: "hello"))
    }

    func testRestoreReadsPagesAndScannerSkipsKnownFiles() async throws {
        let store = try Store.inMemory(); let s = Settings(store); let g = FakeGateway(); g.auth = .ready(name: "T", phoneMasked: nil)
        s.accountState = .ready
        let auth = AccountAuth(gateway: g, settings: s, secrets: MemSecrets(), folders: { ("/tmp/db", "/tmp/files") }, settleMs: 100)
        let t: Int64 = 1_700_000_000_000
        g.pages = [TdHistory(captions: [cap("IMG_1.HEIC", t), "not ours"], oldestId: 900),
                   TdHistory(captions: [cap("IMG_2.HEIC", t + 60_000)], oldestId: 500)]
        let r = HistoryRestorer(store: store, gateway: g, auth: auth)
        let n = await r.run(chatId: -100)
        XCTAssertEqual(n, 2)
        XCTAssertFalse(r.needed(chatId: -100))
        XCTAssertTrue(store.isRestored(Caption.key(displayName: "IMG_1.HEIC", takenAt: t)))
        XCTAssertFalse(store.isRestored(Caption.key(displayName: "IMG_3.HEIC", takenAt: t)))
        let again = await r.run(chatId: -100); XCTAssertEqual(again, 0)   // done once, not repeated
    }

    func testFailedHistoryIsRetriedLater() async throws {
        let store = try Store.inMemory(); let s = Settings(store); let g = FakeGateway(); g.auth = .ready(name: "T", phoneMasked: nil); s.accountState = .ready
        let auth = AccountAuth(gateway: g, settings: s, secrets: MemSecrets(), folders: { ("/tmp/db", "/tmp/files") }, settleMs: 100)
        g.pages = [TdHistory(captions: [], oldestId: nil, failed: true)]
        let r = HistoryRestorer(store: store, gateway: g, auth: auth)
        let n = await r.run(chatId: -100); XCTAssertNil(n)
        XCTAssertTrue(r.needed(chatId: -100))
    }
}
