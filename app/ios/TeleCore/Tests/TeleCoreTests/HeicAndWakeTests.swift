import XCTest
@testable import TeleCore

struct FakeConverter: ImageConverter {
    var ok = true
    func toJpeg(source: String, dest: String, maxBytes: Int64) -> Bool { if ok { try? Data(count: 500).write(to: URL(fileURLWithPath: dest)) }; return ok }
}

final class HeicAndWakeTests: XCTestCase {
    func make(converter: ImageConverter?) throws -> (Store, Settings, UploadEngine, FakeSender, FakeSource, Rule, LibraryScanner, FixedClock, ControlService) {
        let store = try Store.inMemory(); let settings = Settings(store); let clock = FixedClock(10 * Time.day); let events = EventLog(store, clock)
        let rules = RuleService(store: store, settings: settings, events: events, clock: clock)
        let control = ControlService(settings: settings, events: events, clock: clock)
        let src = FakeSource(); let bot = FakeSender(); settings.chatId = -100
        let engine = UploadEngine(store: store, settings: settings, events: events, clock: clock, pacer: Pacer(clock: clock, botPerMinute: 6000, burst: 100), exporter: FakeExporter(src), hasher: FakeHasher(), sender: bot, control: control)
        engine.converter = converter
        var r = Rule(name: "Gallery", folderPath: "smart:recents"); r.topicId = 3; r.startMode = .everything; r.mediaTypes = .photos
        let rule = try rules.save(r)
        src.items = [MediaItem(path: "h", displayName: "IMG_0001.HEIC", mimeType: "image/heic", sizeBytes: 4000, modifiedAt: 1, takenAt: 1, width: 4032, height: 3024, durationMs: nil, kind: .photo)]
        return (store, settings, engine, bot, src, rule, LibraryScanner(source: src, store: store, settings: settings, events: events, clock: clock), clock, control)
    }

    func testHeicInMediaModeGoesAsJpegPhoto() async throws {
        let (store, _, engine, bot, _, rule, scanner, _, _) = try make(converter: FakeConverter())
        scanner.scan(rule); _ = await engine.run()
        XCTAssertEqual(bot.sent.count, 1)
        let j = bot.sent[0]
        XCTAssertEqual(j.sendAs, .photo); XCTAssertEqual(j.displayName, "IMG_0001.jpg"); XCTAssertEqual(j.mimeType, "image/jpeg"); XCTAssertEqual(j.sizeBytes, 500)
        XCTAssertTrue(j.caption.hasPrefix("IMG_0001.HEIC\n"))   // the caption keeps the real name
        let f = try XCTUnwrap(store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 1).first)
        XCTAssertEqual(f.state, .verified); XCTAssertEqual(f.displayName, "IMG_0001.HEIC")
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.path))   // scratch copies are cleaned up
    }
    func testHeicFallsBackToOriginalFileWhenConversionFails() async throws {
        let (store, _, engine, bot, _, rule, scanner, _, _) = try make(converter: FakeConverter(ok: false))
        scanner.scan(rule); _ = await engine.run()
        XCTAssertEqual(bot.sent[0].sendAs, .document); XCTAssertEqual(bot.sent[0].displayName, "IMG_0001.HEIC"); XCTAssertEqual(bot.sent[0].sizeBytes, 4000)
        XCTAssertEqual(store.page(ruleId: rule.id, state: .verified, cursor: nil, limit: 3).count, 1)
    }
    func testNoConverterAlsoFallsBack() async throws {
        let (_, _, engine, bot, _, rule, scanner, _, _) = try make(converter: nil)
        scanner.scan(rule); _ = await engine.run()
        XCTAssertEqual(bot.sent[0].sendAs, .document)
    }

    func testWakePlannerPicksEarliest() async throws {
        let (store, settings, engine, bot, _, rule, scanner, clock, control) = try make(converter: FakeConverter())
        settings.lastScanAt = clock.now()
        XCTAssertEqual(WakePlanner.nextWake(store: store, settings: settings, now: clock.now()), clock.now() + Time.day)
        // a failed upload retries in minutes: the planner wants that time
        scanner.scan(rule); bot.results = [.failed(.badRequest("x"))]; _ = await engine.run()
        let retry = try XCTUnwrap(store.earliestRetryAt())
        XCTAssertEqual(WakePlanner.nextWake(store: store, settings: settings, now: clock.now()), max(clock.now() + 60_000, retry))
        // a delay that ends sooner wins
        settings.lastScanAt = clock.now(); control.delay(minutes: 15)
        let n = WakePlanner.nextWake(store: store, settings: settings, now: clock.now())
        XCTAssertLessThanOrEqual(n, clock.now() + 15 * Time.minute + 1)
    }
    func testDelayEndsByItself() throws {
        let (_, settings, _, _, _, _, _, clock, control) = try make(converter: nil)
        control.delay(minutes: 120)
        XCTAssertFalse(control.resumeIfDelayExpired()); XCTAssertEqual(settings.controlState, .delayed)
        clock.t += 121 * Time.minute
        XCTAssertTrue(control.allowsRun)            // already allowed to run
        XCTAssertTrue(control.resumeIfDelayExpired()); XCTAssertEqual(settings.controlState, .running); XCTAssertNil(settings.delayedUntil)
        control.pause(); clock.t += 10 * Time.day
        XCTAssertFalse(control.resumeIfDelayExpired())   // a pause never ends by itself
    }
    func testFailedUploadsRetryOnTheirOwnAfterBackoff() async throws {
        let (store, _, engine, bot, _, rule, scanner, clock, _) = try make(converter: FakeConverter())
        scanner.scan(rule)
        bot.results = [.failed(.badRequest("x")), .failed(.server(code: 502, consecutive: 3))]
        _ = await engine.run()
        var f = try XCTUnwrap(store.page(ruleId: rule.id, state: nil, cursor: nil, limit: 1).first)
        XCTAssertEqual(f.state, .failed)
        _ = await engine.run()                                  // too early: it waits
        XCTAssertEqual(bot.sent.count, 1)
        clock.t += 3 * Time.minute; _ = await engine.run()      // backoff over: tried again by itself
        XCTAssertEqual(bot.sent.count, 2)
        clock.t += 10 * Time.minute; _ = await engine.run()     // and again, now it works
        f = try XCTUnwrap(store.file(id: f.id)); XCTAssertEqual(f.state, .verified)
    }
}
