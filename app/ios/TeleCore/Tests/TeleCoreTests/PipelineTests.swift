import XCTest
@testable import TeleCore

final class FakeSource: MediaSource {
    var items: [MediaItem] = []
    func list(album: String, types: MediaTypes) -> [MediaItem] { items }
    func exists(_ path: String) -> Bool { items.contains { $0.path == path } }
    func albumExists(_ album: String) -> Bool { true }
}
final class FakeExporter: AssetExporter {
    let src: FakeSource; let dir: URL
    init(_ s: FakeSource) { src = s; dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func export(_ id: String, displayName: String) async throws -> ExportedFile {
        let p = dir.appendingPathComponent(UUID().uuidString).path
        let size = src.items.first { $0.path == id }?.sizeBytes ?? 0
        try Data(count: Int(size)).write(to: URL(fileURLWithPath: p)); return ExportedFile(path: p, sizeBytes: size)
    }
    func facts(_ id: String) -> DiskFacts {
        guard let i = src.items.first(where: { $0.path == id }) else { return DiskFacts(exists: false, sizeBytes: 0, modifiedAt: 0) }
        return DiskFacts(exists: true, sizeBytes: i.sizeBytes, modifiedAt: i.modifiedAt)
    }
}
struct FakeHasher: Hasher { func sha256(path: String) throws -> String { "abcdef0123456789" } }
final class FakeSender: TelegramSender {
    var results: [SendResult] = []; var sent: [SendJob] = []; var echo = true
    func send(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> SendResult {
        sent.append(job)
        if !results.isEmpty { return results.removeFirst() }
        return .sent(SentMessage(chatId: job.chatId, threadId: job.threadId, messageId: Int64(100 + sent.count), size: job.sizeBytes, width: job.width, height: job.height, durationMs: job.durationMs, kind: job.sendAs))
    }
}
final class FakeDeleter: PhotoDeleter {
    var said = true; var asked: [String] = []
    func deleteBatch(_ ids: [String]) async -> Set<String> { asked = ids; return said ? Set(ids) : [] }
}

final class PipelineTests: XCTestCase {
    var store: Store!; var settings: Settings!; var clock: FixedClock!; var events: EventLog!; var source: FakeSource!
    var sender: FakeSender!; var deleter: FakeDeleter!; var rules: RuleService!; var engine: UploadEngine!; var cleaner: Cleaner!; var scanner: LibraryScanner!
    var control: ControlService!

    override func setUpWithError() throws {
        store = try Store.inMemory(); settings = Settings(store); clock = FixedClock(10 * Time.day); events = EventLog(store, clock)
        source = FakeSource(); sender = FakeSender(); deleter = FakeDeleter()
        rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        control = ControlService(settings: settings, events: events, clock: clock)
        let ex = FakeExporter(source)
        engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: Pacer(clock: clock, botPerMinute: 6000, burst: 100), exporter: ex, hasher: FakeHasher(), sender: sender, control: control)
        cleaner = Cleaner(store: store, settings: settings, events: events, clock: clock, exporter: ex, deleter: deleter)
        scanner = LibraryScanner(source: source, store: store, settings: settings, events: events, clock: clock)
        settings.chatId = -100
    }
    func item(_ n: String, taken: Int64, size: Int64 = 2000) -> MediaItem {
        MediaItem(path: "id-\(n)", displayName: "\(n).JPG", mimeType: "image/jpeg", sizeBytes: size, modifiedAt: taken, takenAt: taken, width: 4000, height: 3000, durationMs: nil, kind: .photo)
    }
    func makeRule(delete: Bool) throws -> Rule {
        var r = Rule(name: "Gallery", folderPath: "smart:recents"); r.topicId = 5; r.startMode = .everything; r.retentionDays = 7
        if delete { r.mode = .uploadAndDelete; r.deleteWarningAcceptedAt = clock.now() }
        return try rules.save(r)
    }

    func testScanQueuesOldestFirstAndSkipsTooNew() throws {
        let r = try makeRule(delete: false)
        source.items = [item("b", taken: 3 * Time.day), item("a", taken: 2 * Time.day), item("new", taken: clock.now() - 1000)]
        let res = scanner.scan(r)
        XCTAssertEqual(res.newFiles, 2); XCTAssertEqual(res.tooNew, 1)
        XCTAssertEqual(store.nextInQueue(now: clock.now(), allowBot: true, allowAccount: false)?.displayName, "a.JPG")
        XCTAssertEqual(scanner.scan(r).newFiles, 0)   // a second scan adds nothing
    }

    func testFullPipelineUploadReviewDelete() async throws {
        let r = try makeRule(delete: true)
        source.items = [item("a", taken: 2 * Time.day), item("b", taken: 3 * Time.day)]
        scanner.scan(r)
        let out = await engine.run()
        XCTAssertEqual(out, RunOutcome(filesDone: 2, reason: .queueEmpty))
        XCTAssertEqual(sender.sent.map { $0.threadId }, [5, 5])
        XCTAssertEqual(store.page(ruleId: r.id, state: .verified, cursor: nil, limit: 10).count, 2)
        // not due yet: nothing is offered
        XCTAssertEqual(cleaner.prepareReviews(), 0)
        clock.t += 8 * Time.day
        XCTAssertEqual(cleaner.prepareReviews(), 1)
        let rv = try XCTUnwrap(store.waitingReview(ruleId: r.id)); XCTAssertEqual(rv.fileCount, 2)
        // approving is what raises the iOS prompt; declining deletes nothing
        cleaner.approve(rv.id); deleter.said = false
        var res = await cleaner.deleteApproved(reviewId: rv.id)
        XCTAssertTrue(res.declined); XCTAssertEqual(store.page(ruleId: r.id, state: .deleted, cursor: nil, limit: 10).count, 0)
        deleter.said = true
        res = await cleaner.deleteApproved(reviewId: rv.id)
        XCTAssertEqual(res.deleted, 2); XCTAssertEqual(res.freedBytes, 4000)
        XCTAssertEqual(deleter.asked.count, 2)
    }

    func testUploadOnlyRuleNeverOffersDelete() async throws {
        let r = try makeRule(delete: false)
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(r); _ = await engine.run()
        clock.t += 30 * Time.day
        XCTAssertEqual(cleaner.prepareReviews(), 0)
    }

    func testFailedUploadIsNeverDeleted() async throws {
        let r = try makeRule(delete: true)
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(r)
        sender.results = Array(repeating: .failed(.badRequest("nope")), count: 5)
        for _ in 0..<5 { _ = await engine.run(); clock.t += 7 * Time.hour }
        let f = try XCTUnwrap(store.page(ruleId: r.id, state: nil, cursor: nil, limit: 5).first)
        XCTAssertEqual(f.state, .skipped)
        clock.t += 30 * Time.day
        XCTAssertEqual(cleaner.prepareReviews(), 0)
    }

    func testWrongReplyIsNotVerified() async throws {
        let r = try makeRule(delete: true)
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(r)
        sender.results = [.sent(SentMessage(chatId: -100, threadId: 99, messageId: 7, size: 5, kind: .photo))]
        _ = await engine.run()
        XCTAssertNil(store.page(ruleId: r.id, state: .verified, cursor: nil, limit: 5).first)
    }

    func testEditedAfterUploadIsNotDeleted() async throws {
        let r = try makeRule(delete: true)
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(r); _ = await engine.run()
        clock.t += 8 * Time.day; cleaner.prepareReviews()
        let rv = try XCTUnwrap(store.waitingReview(ruleId: r.id)); cleaner.approve(rv.id)
        source.items[0].modifiedAt += 5     // person edited the photo
        let res = await cleaner.deleteApproved(reviewId: rv.id)
        XCTAssertEqual(res.deleted, 0); XCTAssertEqual(res.denied, 1); XCTAssertTrue(deleter.asked.isEmpty)
    }

    func testPausedRunDoesNothingAndFloodWaitBlocks() async throws {
        let r = try makeRule(delete: false)
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(r)
        control.pause()
        let o = await engine.run(); XCTAssertEqual(o.reason, .paused); XCTAssertTrue(sender.sent.isEmpty)
        control.resume(); sender.results = [.failed(.floodWait(seconds: 30))]
        _ = await engine.run()
        XCTAssertEqual(store.page(ruleId: r.id, state: .queued, cursor: nil, limit: 5).count, 1)
        XCTAssertGreaterThan(store.file(id: store.page(ruleId: r.id, state: nil, cursor: nil, limit: 1)[0].id)!.nextAttemptAt ?? 0, clock.now())
    }

    func testRuleValidation() throws {
        XCTAssertThrowsError(try rules.save(Rule(name: "", folderPath: "smart:recents")))
        _ = try makeRule(delete: false)
        XCTAssertThrowsError(try rules.save(Rule(name: "gallery", folderPath: "smart:screenshots")))   // same name, any case
        var d = Rule(name: "Del", folderPath: "smart:videos"); d.mode = .uploadAndDelete
        XCTAssertThrowsError(try rules.save(d))   // needs the warning first
    }

    func testKillSwitch() throws {
        let r = try makeRule(delete: true)
        rules.stopAllDeletes()
        let back = try XCTUnwrap(rules.get(r.id)); XCTAssertEqual(back.mode, .uploadOnly); XCTAssertNil(back.deleteWarningAcceptedAt)
    }

    func testCaption() {
        let c = Caption.build(displayName: "IMG_1.HEIC", takenAt: 0, ruleName: "Gallery", sha256: "abcdef0123456789")
        XCTAssertTrue(c.hasPrefix("IMG_1.HEIC\n")); XCTAssertTrue(c.hasSuffix("#tb abcdef012345")); XCTAssertLessThanOrEqual(c.count, 1024)
        XCTAssertEqual(Caption.shorten("abcdefghij", 7), "ab...ij")
    }
}

final class FakeBackground: BackgroundUploading {
    var submitted: [(SendJob, Int64)] = [], active: Set<Int64> = [], refuse = false
    func submit(_ job: SendJob, fileId: Int64) -> String? { if refuse { return nil }; submitted.append((job, fileId)); return "/tmp/none-\(fileId)" }
    func activeFileIds() async -> Set<Int64> { active }
    var cancelled = 0
    func cancelAll() { cancelled += 1 }
}

final class BackgroundUploadTests: XCTestCase {
    var store: Store!; var settings: Settings!; var clock: FixedClock!; var source: FakeSource!; var engine: UploadEngine!; var bg: FakeBackground!
    var scanner: LibraryScanner!; var rule: Rule!; var sender: FakeSender!

    override func setUpWithError() throws {
        store = try Store.inMemory(); settings = Settings(store); clock = FixedClock(10 * Time.day)
        let events = EventLog(store, clock); source = FakeSource(); sender = FakeSender(); bg = FakeBackground()
        let rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        let control = ControlService(settings: settings, events: events, clock: clock)
        engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: Pacer(clock: clock, botPerMinute: 6000, burst: 100),
                              exporter: FakeExporter(source), hasher: FakeHasher(), sender: sender, control: control)
        engine.background = bg
        scanner = LibraryScanner(source: source, store: store, settings: settings, events: events, clock: clock)
        settings.chatId = -100
        var r = Rule(name: "Gallery", folderPath: "smart:recents"); r.topicId = 5; r.startMode = .everything
        rule = try rules.save(r)
    }
    func item(_ n: String, taken: Int64, size: Int64 = 2000) -> MediaItem {
        MediaItem(path: "id-\(n)", displayName: "\(n).JPG", mimeType: "image/jpeg", sizeBytes: size, modifiedAt: taken, takenAt: taken, width: 4000, height: 3000, durationMs: nil, kind: .photo)
    }
    func reply(_ id: Int) -> Data {
        Data(#"{"ok":true,"result":{"message_id":\#(id),"message_thread_id":5,"chat":{"id":-100},"photo":[{"file_id":"x","file_unique_id":"u","width":4000,"height":3000,"file_size":2000}]}}"#.utf8)
    }

    func testFilesAreHandedToTheSystemNotSentInline() async throws {
        source.items = [item("a", taken: 2 * Time.day), item("b", taken: 3 * Time.day)]; scanner.scan(rule)
        _ = await engine.run()
        XCTAssertEqual(bg.submitted.count, 2)
        XCTAssertTrue(sender.sent.isEmpty)
        let id = bg.submitted[0].1
        XCTAssertEqual(store.file(id: id)?.state, .uploading)
        XCTAssertEqual(store.bgOutstanding().count, 2)
    }

    func testAnswerArrivingLaterVerifiesTheFile() async throws {
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(rule); _ = await engine.run()
        let id = bg.submitted[0].1
        engine.completeBackground(fileId: id, httpCode: 200, data: reply(77), error: nil)
        let f = try XCTUnwrap(store.file(id: id))
        XCTAssertEqual(f.state, .verified); XCTAssertEqual(f.tgMessageId, 77)
        XCTAssertEqual(settings.lastUploadAt, clock.now())   // shown on Home as "last upload"
        XCTAssertEqual(store.bgOutstanding().count, 0)
    }

    func testNetworkErrorPutsFileBackWithoutCountingAnAttempt() async throws {
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(rule); _ = await engine.run()
        let id = bg.submitted[0].1
        engine.completeBackground(fileId: id, httpCode: 0, data: Data(), error: URLError(.notConnectedToInternet))
        let f = try XCTUnwrap(store.file(id: id)); XCTAssertEqual(f.attempts, 0)
        XCTAssertTrue([.queued, .failed].contains(f.state))
    }

    func testFileInTheSystemIsNotTreatedAsInterrupted() async throws {
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(rule); _ = await engine.run()
        let id = bg.submitted[0].1
        bg.active = [id]; _ = await engine.run()   // a second run must leave it alone
        XCTAssertEqual(store.file(id: id)?.state, .uploading)
        XCTAssertEqual(bg.submitted.count, 1)
    }

    func testLostTaskGoesBackToQueueAfterWaiting() async throws {
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(rule); _ = await engine.run()
        let id = bg.submitted[0].1
        clock.t += 20 * Time.minute; bg.active = []
        _ = await engine.run()
        XCTAssertGreaterThanOrEqual(bg.submitted.count, 2)   // re-queued and handed over again
        XCTAssertEqual(store.file(id: id)?.state, .uploading)
    }

    func testLimitStopsHandOverButRunEnds() async throws {
        source.items = (0..<3).map { item("f\($0)", taken: Int64($0 + 2) * Time.day, size: 30_000_000) }; scanner.scan(rule); engine.handoffMaxBytes = 70_000_000
        let out = await engine.run()
        XCTAssertEqual(bg.submitted.count, 2)   // byte cap
        XCTAssertEqual(out.reason, .nothingToSend)
    }

    func testRefusedSubmitDoesNotLoseTheFile() async throws {
        bg.refuse = true
        source.items = [item("a", taken: 2 * Time.day)]; scanner.scan(rule); _ = await engine.run()
        let f = try XCTUnwrap(store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 5).first)
        XCTAssertEqual(f.state, .queued); XCTAssertEqual(store.bgOutstanding().count, 0)
    }

    func testPauseCancelsSystemUploadsAndRequeuesFiles() async throws {
        source.items = [item("a", taken: 2 * Time.day), item("b", taken: 3 * Time.day)]; scanner.scan(rule); _ = await engine.run()
        XCTAssertEqual(store.bgOutstanding().count, 2)
        engine.cancelBackground()
        XCTAssertEqual(bg.cancelled, 1); XCTAssertEqual(store.bgOutstanding().count, 0)
        let states = store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 10).map { $0.state }
        XCTAssertEqual(states, [.queued, .queued])
    }
}
