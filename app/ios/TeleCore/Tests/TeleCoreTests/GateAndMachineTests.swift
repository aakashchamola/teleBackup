import XCTest
@testable import TeleCore

final class GateAndMachineTests: XCTestCase {
    func verifiedFile() -> FileRecord {
        var f = FileRecord(ruleId: 1, path: "A1", displayName: "IMG_1.HEIC", mimeType: "image/heic", kind: .photo,
                           sizeBytes: 1000, modifiedAt: 5, takenAt: 5)
        f.id = 7; f.state = .verified; f.tgMessageId = 9; f.tgChatId = 3; f.deleteAfter = 100; f.route = .bot
        return f
    }
    func deletingRule() -> Rule {
        var r = Rule(name: "Gallery", folderPath: "smart:recents")
        r.id = 1; r.mode = .uploadAndDelete; r.deleteWarningAcceptedAt = 1; r.dryRun = false
        return r
    }
    let disk = DiskFacts(exists: true, sizeBytes: 1000, modifiedAt: 5)

    func gate(_ f: FileRecord? = nil, _ r: Rule? = nil, blocked: String? = nil, disk d: DiskFacts? = nil, now: Int64 = 200,
              review: Bool = false, account: AccountCheck = .ok, botOnly: Bool = false) -> GateResult {
        DeleteGate.check(file: f ?? verifiedFile(), rule: r ?? deletingRule(), deletesBlockedReason: blocked, disk: d ?? disk,
                         now: now, inApprovedReview: review, account: account, allowBotOnly: botOnly)
    }
    func denied(_ g: GateResult) -> DenyReason? { if case .denied(let r) = g { return r }; return nil }

    func testAllowedWhenAllNineHold() {
        if case .allowed(let p) = gate() { XCTAssertEqual(p.fileId, 7) } else { XCTFail("should allow") }
    }
    func testEachDenial() {
        var f = verifiedFile(); f.state = .uploaded
        XCTAssertEqual(denied(gate(f)), .notVerified)
        f = verifiedFile(); f.tgMessageId = nil
        XCTAssertEqual(denied(gate(f)), .notVerified)
        f = verifiedFile(); f.partCount = 3
        XCTAssertEqual(denied(gate(f)), .sentInParts)
        var r = deletingRule(); r.mode = .uploadOnly
        XCTAssertEqual(denied(gate(nil, r)), .ruleUploadOnly)
        r = deletingRule(); r.deleteWarningAcceptedAt = nil
        XCTAssertEqual(denied(gate(nil, r)), .noWarningAccepted)
        r = deletingRule(); r.enabled = false
        XCTAssertEqual(denied(gate(nil, r)), .ruleOff)
        XCTAssertEqual(denied(gate(blocked: "kill switch")), .deletesBlocked)
        XCTAssertEqual(denied(gate(now: 50)), .notDue)
        r = deletingRule(); r.dryRun = true
        XCTAssertEqual(denied(gate(nil, r)), .needsReview)
        if case .allowed = gate(nil, r, review: true) {} else { XCTFail("approved review allows") }
        XCTAssertEqual(denied(gate(disk: DiskFacts(exists: false, sizeBytes: 0, modifiedAt: 0))), .fileMissing)
        XCTAssertEqual(denied(gate(disk: DiskFacts(exists: true, sizeBytes: 999, modifiedAt: 5))), .fileChanged)
        XCTAssertEqual(denied(gate(disk: DiskFacts(exists: true, sizeBytes: 1000, modifiedAt: 6))), .fileChanged)
        XCTAssertEqual(denied(gate(account: .mismatch)), .telegramMismatch)
        XCTAssertEqual(denied(gate(account: .notFound)), .telegramMismatch)
        XCTAssertEqual(denied(gate(account: .unavailable)), .noStrongCheck)
        XCTAssertEqual(denied(gate(account: .notReady, botOnly: false)), .noStrongCheck)
        if case .allowed = gate(account: .notReady, botOnly: true) {} else { XCTFail("bot-only allowed by owner") }
        f = verifiedFile(); f.route = .account
        XCTAssertEqual(denied(gate(f, account: .notReady, botOnly: true)), .noStrongCheck)
    }

    // 20,000 random cases: allowed only when every condition holds.
    func testRandomGateNeverAllowsWrongly() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            var f = verifiedFile(); var r = deletingRule()
            var ok = true
            if Bool.random(using: &rng) { f.state = .uploaded; ok = false }
            if Bool.random(using: &rng) { r.mode = .uploadOnly; ok = false }
            if Bool.random(using: &rng) { r.enabled = false; ok = false }
            if Bool.random(using: &rng) { r.dryRun = true; ok = false }
            let blocked: String? = Bool.random(using: &rng) ? "x" : nil; if blocked != nil { ok = false }
            let changed = Bool.random(using: &rng); if changed { ok = false }
            let acc: AccountCheck = [.ok, .notReady, .mismatch, .unavailable, .notFound].randomElement(using: &rng)!
            if acc != .ok { ok = false }
            let g = DeleteGate.check(file: f, rule: r, deletesBlockedReason: blocked,
                                     disk: DiskFacts(exists: true, sizeBytes: changed ? 1 : 1000, modifiedAt: 5), now: 200,
                                     inApprovedReview: false, account: acc, allowBotOnly: false)
            if case .allowed = g { XCTAssertTrue(ok) } else { XCTAssertFalse(ok) }
        }
    }

    // state machine
    func queued() -> FileRecord { var f = verifiedFile(); f.state = .queued; f.tgMessageId = nil; f.tgChatId = nil; f.deleteAfter = nil; return f }
    func sentMsg() -> SentMessage { SentMessage(chatId: 3, threadId: 4, messageId: 9, size: 1000, kind: .document) }

    func testHappyPath() throws {
        var f = queued()
        f = try FileStateMachine.transition(f, .startUpload, now: 10)
        f = try FileStateMachine.transition(f, .sent(sentMsg(), sha256: "ab"), now: 11)
        XCTAssertEqual(f.state, .uploaded)
        f = try FileStateMachine.transition(f, .replyOk(deleteAfter: 99), now: 12)
        XCTAssertEqual(f.state, .verified); XCTAssertEqual(f.deleteAfter, 99)
        guard case .allowed(let p) = gate(f) else { return XCTFail() }
        f.id = 7
        f = try FileStateMachine.transition(f, .deletedByCleaner(p, freedBytes: 1000), now: 300)
        XCTAssertEqual(f.state, .deleted); XCTAssertEqual(f.freedBytes, 1000)
    }
    func testIllegalMovesThrow() {
        XCTAssertThrowsError(try FileStateMachine.transition(queued(), .replyOk(deleteAfter: nil), now: 1))
        XCTAssertThrowsError(try FileStateMachine.transition(queued(), .sent(sentMsg(), sha256: nil), now: 1))
        var f = queued(); f.state = .uploaded
        XCTAssertThrowsError(try FileStateMachine.transition(f, .startUpload, now: 1))
    }
    func testFailuresAndBackoff() throws {
        var f = queued(); f.state = .uploading; f.route = .bot
        let flood = try FileStateMachine.transition(f, .tgFailed(.floodWait(seconds: 30)), now: 1000)
        XCTAssertEqual(flood.state, .queued); XCTAssertEqual(flood.nextAttemptAt, 1000 + 31_000)
        let big = try FileStateMachine.transition(f, .tgFailed(.tooLarge), now: 1)
        XCTAssertEqual(big.route, .account); XCTAssertEqual(big.state, .queued)
        f.route = .account
        XCTAssertEqual(try FileStateMachine.transition(f, .tgFailed(.tooLarge), now: 1).state, .skipped)
        var bad = f
        for _ in 0..<4 { bad.state = .uploading; bad = try FileStateMachine.transition(bad, .tgFailed(.badRequest("x")), now: 1); XCTAssertEqual(bad.state, .failed) }
        bad.state = .uploading
        XCTAssertEqual(try FileStateMachine.transition(bad, .tgFailed(.badRequest("x")), now: 1).state, .skipped)
        XCTAssertEqual(Backoff.delayMillis(attempt: 1), 2 * Time.minute)
        XCTAssertEqual(Backoff.delayMillis(attempt: 20), 6 * Time.hour)
    }
    func testCrashRecovery() throws {
        var f = queued(); f.state = .uploading
        XCTAssertEqual(try FileStateMachine.transition(f, .recoverAfterCrash, now: 1).state, .queued)
        f.tgMessageId = 5
        XCTAssertEqual(try FileStateMachine.transition(f, .recoverAfterCrash, now: 1).state, .uploaded)
    }
    func testTelegramLostClearsTelegramFields() throws {
        let f = try FileStateMachine.transition(verifiedFile(), .telegramLost, now: 1)
        XCTAssertEqual(f.state, .queued); XCTAssertNil(f.tgMessageId); XCTAssertNil(f.deleteAfter)
    }

    // router, verifier, pacer
    func testRouter() {
        XCTAssertEqual(Router.decide(sizeBytes: 1_000_000, kind: .photo, uploadAs: .media, displayName: "a.jpg", width: 4000, height: 3000), .go(.bot, .photo))
        XCTAssertEqual(Router.decide(sizeBytes: 1_000_000, kind: .photo, uploadAs: .media, displayName: "a.HEIC", width: 4000, height: 3000), .go(.bot, .photo, note: "converted to JPEG"))
        XCTAssertEqual(Router.decide(sizeBytes: 1_000_000, kind: .photo, uploadAs: .media, displayName: "a.dng", width: 4000, height: 3000), .go(.bot, .document, note: "odd photo type"))
        XCTAssertEqual(Router.decide(sizeBytes: 1_000_000, kind: .photo, uploadAs: .original, displayName: "a.HEIC", width: 4000, height: 3000), .go(.bot, .document))
        XCTAssertEqual(Router.decide(sizeBytes: 60_000_000, kind: .video, uploadAs: .media, displayName: "a.mov", width: nil, height: nil), .go(.account, .video))
        XCTAssertEqual(Router.decide(sizeBytes: 1000, kind: .photo, uploadAs: .original, displayName: "a.jpg", width: 1, height: 1), .go(.bot, .document))
        XCTAssertEqual(Router.decide(sizeBytes: 2_100_000_000, kind: .video, uploadAs: .media, displayName: "a.mov", width: nil, height: nil), .go(.account, .video, note: "cut into 2 parts", parts: 2))
    }
    func testVerifier() {
        let job = SendJob(chatId: 3, threadId: 4, path: "p", displayName: "a", mimeType: "x", sendAs: .document, caption: "", sizeBytes: 1000)
        XCTAssertEqual(Verifier.checkReply(job, sentMsg()), .ok)
        var wrong = sentMsg(); wrong.size = 5
        if case .mismatch = Verifier.checkReply(job, wrong) {} else { XCTFail() }
        wrong = sentMsg(); wrong.threadId = 9
        XCTAssertEqual(Verifier.checkReply(job, wrong), .mismatch("wrong topic"))
    }
    func testPacerBurstThenWait() {
        let c = FixedClock(0); let p = Pacer(clock: c)
        XCTAssertEqual(p.reserve(.bot), 0); XCTAssertEqual(p.reserve(.bot), 0); XCTAssertEqual(p.reserve(.bot), 0)
        XCTAssertGreaterThan(p.reserve(.bot), 0)
        p.blockAll(until: 60_000)
        XCTAssertGreaterThanOrEqual(p.reserve(.account), 60_000)
    }
}
