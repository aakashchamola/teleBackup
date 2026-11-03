import Foundation

public struct IllegalTransition: Error, CustomStringConvertible {
    public let from: FileState
    public let event: String
    public var description: String { "Cannot apply \(event) to a \(from) file" }
}

/// A permit to delete one file. Only `DeleteGate` can make one (internal init), and
/// `FileEvent.deletedByCleaner` needs one, so `.deleted` cannot be reached any other way.
public struct DeletePermit {
    public let fileId: Int64
    init(fileId: Int64) { self.fileId = fileId }
}

public enum FileEvent {
    case startUpload, networkStop
    case sent(SentMessage, sha256: String?)
    case replyOk(deleteAfter: Int64?)
    case replyMismatch(String)
    case tgFailed(TgError)
    case backoffDue, giveUp, retryByPerson, changed, vanished, ignore, recoverAfterCrash, telegramLost
    case deletedByCleaner(DeletePermit, freedBytes: Int64)

    var name: String { String(describing: self).components(separatedBy: "(").first ?? "event" }
}

public enum Backoff {
    /// After failed attempt number n: 2^n minutes up to 6 hours, plus up to 20%.
    public static func delayMillis(attempt: Int, jitter01: Double = 0) -> Int64 {
        let minutes = Int64(1) << Int64(min(max(attempt, 0), 20))
        let base = min(minutes * Time.minute, 6 * Time.hour)
        return base + Int64(Double(base) * 0.2 * min(max(jitter01, 0), 1))
    }
}

/// The only place a file's state changes (docs/DATA_MODEL.md "File state machine").
public enum FileStateMachine {
    public static let defaultMaxAttempts = 5

    public static func transition(_ file: FileRecord, _ event: FileEvent, now: Int64,
                                  maxAttempts: Int = defaultMaxAttempts, jitter01: Double = 0) throws -> FileRecord {
        let s = file.state
        func need(_ ok: Bool) throws { if !ok { throw IllegalTransition(from: s, event: event.name) } }
        var f = file
        switch event {
        case .startUpload:
            try need(s == .queued); f.state = .uploading
        case .networkStop:
            try need(s == .uploading); f.state = .queued
        case .sent(let m, let sha):
            try need(s == .uploading)
            f.state = .uploaded; f.sha256 = sha ?? f.sha256; f.sendAs = m.kind
            f.tgChatId = m.chatId; f.tgThreadId = m.threadId; f.tgMessageId = m.messageId
            f.tgFileUniqueId = m.fileUniqueId; f.tgSize = m.size; f.tgWidth = m.width; f.tgHeight = m.height
            f.tgDurationMs = m.durationMs; f.uploadedAt = now; f.lastError = nil
        case .replyOk(let due):
            try need(s == .uploaded)
            f.state = .verified; f.verifiedAt = now; f.deleteAfter = due; f.attempts = 0; f.nextAttemptAt = nil
        case .replyMismatch(let reason):
            try need(s == .uploaded)
            f = countedFailure(file, "Telegram's reply did not match: \(reason)", now, maxAttempts, jitter01, clear: true)
        case .tgFailed(let err):
            try need(s == .uploading)
            f = failed(file, err, now, maxAttempts, jitter01)
        case .backoffDue:
            try need(s == .failed); f.state = .queued
        case .giveUp:
            try need(s == .failed); f.state = .skipped; f.nextAttemptAt = nil
        case .retryByPerson:
            try need(s == .skipped || s == .failed)
            f.state = .queued; f.attempts = 0; f.nextAttemptAt = nil; f.lastError = nil
        case .changed:
            try need(s == .verified); f.state = .changed; f.deleteAfter = nil
        case .vanished:
            try need([.queued, .uploading, .failed, .skipped, .verified].contains(s))
            f.state = .gone; f.deleteAfter = nil
        case .ignore:
            try need([.queued, .failed, .skipped].contains(s)); f.state = .ignored; f.nextAttemptAt = nil
        case .recoverAfterCrash:
            try need(s == .uploading); f.state = file.tgMessageId != nil ? .uploaded : .queued
        case .telegramLost:
            try need(s == .verified)
            f.state = .queued; f.deleteAfter = nil
            f = clearTelegram(f)
        case .deletedByCleaner(let permit, let freed):
            try need(s == .verified)
            precondition(permit.fileId == file.id, "Permit is for another file")
            f.state = .deleted; f.deletedAt = now; f.freedBytes = freed; f.deleteAfter = nil
        }
        f.updatedAt = now
        return f
    }

    private static func failed(_ file: FileRecord, _ err: TgError, _ now: Int64, _ max: Int, _ jitter: Double) -> FileRecord {
        var back = file
        back.state = .queued; back.lastError = err.userMessage
        switch err {
        case .floodWait(let secs):
            back.nextAttemptAt = now + (secs + 1) * 1000; return back
        case .tooLarge:
            if file.route == .bot { back.route = .account; return back }
            var s = file; s.state = .skipped; s.lastError = "Too big for Telegram."; s.nextAttemptAt = nil; return s
        case .badRequest:
            return countedFailure(file, err.userMessage, now, max, jitter)
        case .server(_, let consecutive):
            if consecutive >= 3 { return countedFailure(file, err.userMessage, now, max, jitter) }
            back.nextAttemptAt = now + 30_000; return back
        case .topicMissing, .badToken, .forbidden, .chatMigrated, .network, .accountLoggedOut:
            return back
        }
    }

    private static func countedFailure(_ file: FileRecord, _ message: String, _ now: Int64, _ max: Int, _ jitter: Double,
                                       clear: Bool = false) -> FileRecord {
        let attempts = file.attempts + 1
        var b = clear ? clearTelegram(file) : file
        b.attempts = attempts; b.lastError = message
        if attempts >= max { b.state = .skipped; b.nextAttemptAt = nil }
        else { b.state = .failed; b.nextAttemptAt = now + Backoff.delayMillis(attempt: attempts, jitter01: jitter) }
        return b
    }

    private static func clearTelegram(_ file: FileRecord) -> FileRecord {
        var f = file
        f.tgChatId = nil; f.tgThreadId = nil; f.tgMessageId = nil; f.tgFileUniqueId = nil
        f.tgSize = nil; f.tgWidth = nil; f.tgHeight = nil; f.tgDurationMs = nil
        f.uploadedAt = nil; f.verifiedAt = nil
        return f
    }
}
