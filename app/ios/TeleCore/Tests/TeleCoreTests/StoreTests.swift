import XCTest
@testable import TeleCore

final class StoreTests: XCTestCase {
    func testRuleRoundTripAndQueueOrder() throws {
        let s = try Store.inMemory()
        var r = Rule(name: "Gallery", folderPath: "smart:recents"); r.mode = .uploadAndDelete; r.startDate = 5; r.topicId = 11
        let id = s.insert(rule: r)
        let back = try XCTUnwrap(s.rule(id: id))
        XCTAssertEqual(back.name, "Gallery"); XCTAssertEqual(back.mode, .uploadAndDelete); XCTAssertEqual(back.topicId, 11); XCTAssertEqual(back.startDate, 5)

        func f(_ p: String, taken: Int64) -> FileRecord { FileRecord(ruleId: id, path: p, displayName: p, mimeType: "image/jpeg", kind: .photo, sizeBytes: 10, modifiedAt: 1, takenAt: taken) }
        XCTAssertEqual(s.insertAll([f("b", taken: 20), f("a", taken: 10), f("a", taken: 10)]), 2)   // duplicate identity skipped
        XCTAssertEqual(s.nextInQueue(now: 100, allowBot: true, allowAccount: false)?.path, "a")        // oldest first
        XCTAssertEqual(s.queueCount(now: 100, allowBot: true, allowAccount: false).count, 2)
        s.update(rule: { var x = back; x.enabled = false; return x }())
        XCTAssertNil(s.nextInQueue(now: 100, allowBot: true, allowAccount: true))
    }
    func testApplyRunsStateMachineAndRefusesIllegal() throws {
        let s = try Store.inMemory()
        let rid = s.insert(rule: Rule(name: "x", folderPath: "smart:recents"))
        s.insertAll([FileRecord(ruleId: rid, path: "a", displayName: "a", mimeType: "x", kind: .photo, sizeBytes: 1, modifiedAt: 1, takenAt: 1)])
        let f = try XCTUnwrap(s.nextInQueue(now: 1, allowBot: true, allowAccount: true))
        XCTAssertEqual(try s.apply(f.id, .startUpload, now: 2).state, .uploading)
        XCTAssertThrowsError(try s.apply(f.id, .startUpload, now: 3))
        XCTAssertEqual(s.interrupted().count, 1)
        var changed = try XCTUnwrap(s.file(id: f.id)); changed.state = .verified
        s.updateDetails(changed)   // cannot move the state
        XCTAssertEqual(s.file(id: f.id)?.state, .uploading)
    }
    func testEventsSettingsReviews() throws {
        let s = try Store.inMemory()
        s.insert(event: EventRecord(at: 1, kind: .uploaded, message: "IMG_1 sent"))
        s.insert(event: EventRecord(at: 2, kind: .failed, message: "boom"))
        XCTAssertEqual(s.events(kinds: [.failed], ruleId: nil, search: nil, beforeId: nil, limit: 10).count, 1)
        XCTAssertEqual(s.events(kinds: nil, ruleId: nil, search: "IMG", beforeId: nil, limit: 10).count, 1)
        s.put("k", "v"); XCTAssertEqual(s.setting("k"), "v"); s.put("k", nil); XCTAssertNil(s.setting("k"))
        let id = s.insert(review: ReviewRecord(ruleId: 1, createdAt: 1, fileCount: 3, totalBytes: 9))
        XCTAssertEqual(s.waitingReview(ruleId: 1)?.id, id)
    }
}
