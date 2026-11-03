import Foundation

public enum MediaTypes: String, Codable { case photos, videos, both }
public enum UploadAs: String, Codable { case media, original }
public enum RuleMode: String, Codable { case uploadOnly, uploadAndDelete }
public enum StartMode: String, Codable { case today, sinceDate, everything }
public enum FileKind: String, Codable { case photo, video }
public enum Route: String, Codable { case bot, account }
public enum SendAs: String, Codable { case photo, video, document }
public enum ReviewStatus: String, Codable { case waiting, approved, dismissed, stale }
public enum ControlValue: String, Codable { case running, paused, delayed }
public enum AccountValue: String, Codable { case none, ready, expired }

public enum FileState: String, Codable {
    case queued, uploading, uploaded, verified, deleted, failed, skipped, ignored, gone, changed
    public var terminal: Bool { self == .deleted || self == .ignored || self == .gone || self == .changed }
}

public enum EventKind: String, Codable {
    case scanDone, queuedBatch, uploaded, verified, verifyFailed, failed, skipped, retried, deleted
    case deleteDenied, changed, gone, reviewCreated, reviewApproved, paused, resumed, delayed
    case runStopped, loginExpired, permissionLost, permissionBack, topicMissing, botProblem
    case killSwitch, settingsChanged
}

public enum DenyReason: String {
    case notVerified, ruleUploadOnly, noWarningAccepted, ruleOff, deletesBlocked, notDue
    case needsReview, fileMissing, fileChanged, telegramMismatch, noStrongCheck, sentInParts
}

/// Times are milliseconds since 1970, as on Android.
public enum Time {
    public static let second: Int64 = 1000
    public static let minute: Int64 = 60_000
    public static let hour: Int64 = 3_600_000
    public static let day: Int64 = 86_400_000
}

public protocol Clock { func now() -> Int64 }
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
public final class FixedClock: Clock {
    public var t: Int64
    public init(_ t: Int64) { self.t = t }
    public func now() -> Int64 { t }
}

public struct Rule: Equatable {
    public var id: Int64 = 0
    public var name: String
    /// On iPhone this is an album: "smart:screenshots", "smart:recents", "smart:videos", or "album:<localIdentifier>".
    public var folderPath: String
    public var includeSubfolders = false
    public var mediaTypes: MediaTypes = .both
    public var topicId: Int64?
    public var uploadAs: UploadAs = .media
    public var mode: RuleMode = .uploadOnly
    public var retentionDays = 7
    public var startMode: StartMode = .today
    public var startDate: Int64?
    public var enabled = true
    public var dryRun = true
    public var deleteWarningAcceptedAt: Int64?
    public var deletedAt: Int64?
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var sortDocuments = false
    public init(name: String, folderPath: String) { self.name = name; self.folderPath = folderPath }
}

public struct TopicRecord: Equatable {
    public var threadId: Int64
    public var chatId: Int64
    public var name: String
    public var madeByApp = true
    public var missing = false
    public var createdAt: Int64 = 0
    public init(threadId: Int64, chatId: Int64, name: String) { self.threadId = threadId; self.chatId = chatId; self.name = name }
}

public struct FileRecord: Equatable {
    public var id: Int64 = 0
    public var ruleId: Int64
    /// PHAsset localIdentifier on iPhone.
    public var path: String
    public var displayName: String
    public var mimeType: String
    public var kind: FileKind
    public var sizeBytes: Int64
    public var modifiedAt: Int64
    public var takenAt: Int64
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var sha256: String?
    public var state: FileState = .queued
    public var route: Route?
    public var sendAs: SendAs?
    public var attempts = 0
    public var nextAttemptAt: Int64?
    public var lastError: String?
    public var tgChatId: Int64?
    public var tgThreadId: Int64?
    public var tgMessageId: Int64?
    public var tgFileUniqueId: String?
    public var tgSize: Int64?
    public var tgWidth: Int?
    public var tgHeight: Int?
    public var tgDurationMs: Int64?
    public var queuedAt: Int64 = 0
    public var uploadedAt: Int64?
    public var verifiedAt: Int64?
    public var deleteAfter: Int64?
    public var deletedAt: Int64?
    public var freedBytes: Int64 = 0
    public var reviewId: Int64?
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var topicId: Int64?
    public var partCount = 1

    public init(ruleId: Int64, path: String, displayName: String, mimeType: String, kind: FileKind,
                sizeBytes: Int64, modifiedAt: Int64, takenAt: Int64) {
        self.ruleId = ruleId; self.path = path; self.displayName = displayName; self.mimeType = mimeType
        self.kind = kind; self.sizeBytes = sizeBytes; self.modifiedAt = modifiedAt; self.takenAt = takenAt
    }
}

public struct ReviewRecord: Equatable {
    public var id: Int64 = 0
    public var ruleId: Int64
    public var createdAt: Int64
    public var fileCount: Int
    public var totalBytes: Int64
    public var status: ReviewStatus = .waiting
    public var decidedAt: Int64?
    public init(ruleId: Int64, createdAt: Int64, fileCount: Int, totalBytes: Int64) {
        self.ruleId = ruleId; self.createdAt = createdAt; self.fileCount = fileCount; self.totalBytes = totalBytes
    }
}

public struct EventRecord: Equatable {
    public var id: Int64 = 0
    public var at: Int64
    public var kind: EventKind
    public var ruleId: Int64?
    public var fileId: Int64?
    public var bytes: Int64?
    public var message: String
    public init(at: Int64, kind: EventKind, message: String, ruleId: Int64? = nil, fileId: Int64? = nil, bytes: Int64? = nil) {
        self.at = at; self.kind = kind; self.message = message; self.ruleId = ruleId; self.fileId = fileId; self.bytes = bytes
    }
}
