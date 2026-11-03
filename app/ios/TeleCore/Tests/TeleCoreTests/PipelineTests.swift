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
