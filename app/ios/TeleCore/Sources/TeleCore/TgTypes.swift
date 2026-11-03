import Foundation

/// What went wrong talking to Telegram. The upload loop acts on the kind, never on text.
public enum TgError: Equatable, Error {
    case floodWait(seconds: Int64)
    case tooLarge
    case topicMissing
    case chatMigrated(newChatId: Int64)
    case badRequest(String)
    case badToken
    case forbidden(String)
    case server(code: Int, consecutive: Int = 1)
    case network
    case accountLoggedOut

    public var userMessage: String {
        switch self {
        case .floodWait(let s): return "Telegram asked us to slow down for \(s) seconds."
        case .tooLarge: return "The file is too big for the bot."
        case .topicMissing: return "The topic was deleted in Telegram."
        case .chatMigrated: return "The group moved to a new id."
        case .badRequest(let d): return "Telegram refused the file: \(d)"
        case .badToken: return "The bot token no longer works."
        case .forbidden(let d): return "The bot cannot post to the group: \(d)"
        case .server(let c, _): return "Telegram had a problem (\(c))."
        case .network: return "No connection to Telegram."
        case .accountLoggedOut: return "The Telegram account is logged out."
        }
    }
}

public struct SendJob: Equatable {
    public var chatId: Int64
    public var threadId: Int64?
    public var path: String            // a file in our scratch folder, already exported from Photos
    public var displayName: String
    public var mimeType: String
    public var sendAs: SendAs
    public var caption: String
    public var sizeBytes: Int64
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public init(chatId: Int64, threadId: Int64?, path: String, displayName: String, mimeType: String, sendAs: SendAs,
                caption: String, sizeBytes: Int64, width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil) {
        self.chatId = chatId; self.threadId = threadId; self.path = path; self.displayName = displayName; self.mimeType = mimeType
        self.sendAs = sendAs; self.caption = caption; self.sizeBytes = sizeBytes; self.width = width; self.height = height
        self.durationMs = durationMs
    }
}

public struct SentMessage: Equatable {
    public var chatId: Int64
    public var threadId: Int64?
    public var messageId: Int64
    public var fileUniqueId: String?
    public var size: Int64?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var kind: SendAs
    public init(chatId: Int64, threadId: Int64?, messageId: Int64, fileUniqueId: String? = nil, size: Int64? = nil,
                width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil, kind: SendAs) {
        self.chatId = chatId; self.threadId = threadId; self.messageId = messageId; self.fileUniqueId = fileUniqueId
        self.size = size; self.width = width; self.height = height; self.durationMs = durationMs; self.kind = kind
    }
}

public enum SendResult: Equatable {
    case sent(SentMessage)
    case failed(TgError)
}

public protocol TelegramSender {
    func send(_ job: SendJob, progress: @escaping (_ sent: Int64, _ total: Int64) -> Void) async -> SendResult
    /// 2 to 10 photos or videos shown together (a video cut into parts). Default: not supported.
    func sendAlbum(_ jobs: [SendJob], progress: @escaping (_ sent: Int64, _ total: Int64) -> Void) async -> AlbumResult
}
public extension TelegramSender {
    func sendAlbum(_ jobs: [SendJob], progress: @escaping (Int64, Int64) -> Void) async -> AlbumResult { .unsupported }
}
