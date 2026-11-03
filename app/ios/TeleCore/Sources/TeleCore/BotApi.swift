import Foundation

public enum ApiResult<T> {
    case ok(T)
    case err(TgError)
    public var value: T? { if case .ok(let v) = self { return v }; return nil }
    public var error: TgError? { if case .err(let e) = self { return e }; return nil }
}

public struct BotUser: Equatable { public var id: Int64; public var username: String; public var name: String }
public struct ChatSummary: Equatable { public var id: Int64; public var title: String; public var type: String }
public struct ChatInfo: Equatable { public var id: Int64; public var title: String; public var isForum: Bool }
public struct MemberInfo: Equatable { public var status: String; public var canManageTopics: Bool; public init(status: String, canManageTopics: Bool) { self.status = status; self.canManageTopics = canManageTopics } }
public struct TopicInfo: Equatable { public var threadId: Int64; public var name: String }

/// One HTTP exchange. A fake in tests, URLSession in the app.
public protocol HTTPTransport {
    /// Sends a request. `bodyFile`, when given, is streamed from disk (big uploads never sit in memory).
    func send(_ request: URLRequest, bodyFile: URL?, progress: ((Int64, Int64) -> Void)?) async throws -> (Int, Data)
}

public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate {
    private let session: URLSession
    private var progressByTask: [Int: (Int64, Int64) -> Void] = [:]
    private let lock = NSLock()
    public override init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 60 * 60 * 6
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        super.init()
    }
    public func send(_ request: URLRequest, bodyFile: URL?, progress: ((Int64, Int64) -> Void)?) async throws -> (Int, Data) {
        let (data, resp): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let handler: (Data?, URLResponse?, Error?) -> Void = { d, r, e in
                if let e = e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r!)) }
            }
            let t: URLSessionTask = bodyFile != nil ? session.uploadTask(with: request, fromFile: bodyFile!, completionHandler: handler)
                                                    : session.dataTask(with: request, completionHandler: handler)
            if let p = progress { lock.lock(); progressByTask[t.taskIdentifier] = p; lock.unlock() }
            t.resume()
        }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Multipart bodies are written to a file first, so the system can upload them in the background.
public enum Multipart {
    public struct Field { public var name: String; public var value: String }
    public struct FilePart { public var name: String; public var filename: String; public var mime: String; public var path: String }

    public static func write(fields: [Field], file: FilePart?, to url: URL, boundary: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        func put(_ s: String) { h.write(s.data(using: .utf8)!) }
        for f in fields {
            put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.name)\"\r\n\r\n\(f.value)\r\n")
        }
        if let p = file {
            let safe = p.filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(p.name)\"; filename=\"\(safe)\"\r\nContent-Type: \(p.mime.isEmpty ? "application/octet-stream" : p.mime)\r\n\r\n")
            let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: p.path))
            defer { try? src.close() }
            while true {
                let chunk = src.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                h.write(chunk)
            }
            put("\r\n")
        }
        put("--\(boundary)--\r\n")
    }
}

/// Telegram Bot API over HTTPS (docs/TELEGRAM.md section 2). The token is read at call time and never logged.
public final class BotApi {
    private let tokenProvider: () -> String?
    private let transport: HTTPTransport
    private let baseUrl: String
    private let scratch: URL

    public init(tokenProvider: @escaping () -> String?, transport: HTTPTransport, baseUrl: String = "https://api.telegram.org", scratch: URL = FileManager.default.temporaryDirectory) {
        self.tokenProvider = tokenProvider; self.transport = transport; self.baseUrl = baseUrl; self.scratch = scratch
    }

    // MARK: pure parts (shared with the background upload path)

    public static func mapError(httpCode: Int, description: String, retryAfter: Int64?, migrateTo: Int64?) -> TgError {
        switch true {
        case httpCode == 429: return .floodWait(seconds: retryAfter ?? 5)
        case httpCode == 413: return .tooLarge
        case httpCode == 400 && migrateTo != nil: return .chatMigrated(newChatId: migrateTo!)
        case httpCode == 400 && description.range(of: "thread not found", options: .caseInsensitive) != nil: return .topicMissing
        case httpCode == 400 && description.range(of: "TOPIC_DELETED", options: .caseInsensitive) != nil: return .topicMissing
        case httpCode == 400: return .badRequest(description)
        case httpCode == 401: return .badToken
        case httpCode == 403: return .forbidden(description)
        case httpCode >= 500: return .server(code: httpCode)
        default: return .badRequest(description.isEmpty ? "HTTP \(httpCode)" : description)
        }
    }

    /// Reads Telegram's reply. `parse` gets the "result" value.
    public static func parse<T>(httpCode: Int, data: Data, _ parse: (Any) -> T) -> ApiResult<T> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .err(httpCode >= 500 ? .server(code: httpCode) : .badRequest("unreadable reply (HTTP \(httpCode))"))
        }
        if root["ok"] as? Bool == true { return .ok(parse(root["result"] ?? NSNull())) }
        let params = root["parameters"] as? [String: Any]
        return .err(mapError(httpCode: (root["error_code"] as? Int) ?? httpCode, description: root["description"] as? String ?? "",
                             retryAfter: (params?["retry_after"] as? NSNumber)?.int64Value, migrateTo: (params?["migrate_to_chat_id"] as? NSNumber)?.int64Value))
    }

    public static func parseSent(_ any: Any, kind: SendAs, fallbackChat: Int64) -> SentMessage {
        let m = any as? [String: Any] ?? [:]
        let chat = ((m["chat"] as? [String: Any])?["id"] as? NSNumber)?.int64Value ?? fallbackChat
        var size: Int64?, w: Int?, h: Int?, dur: Int64?, uniq: String?
        func i64(_ o: [String: Any], _ k: String) -> Int64? { (o[k] as? NSNumber)?.int64Value }
        switch kind {
        case .photo:
            if let o = (m["photo"] as? [[String: Any]])?.last { size = i64(o, "file_size"); w = i64(o, "width").map(Int.init); h = i64(o, "height").map(Int.init); uniq = o["file_unique_id"] as? String }
        case .video:
            if let o = m["video"] as? [String: Any] { size = i64(o, "file_size"); w = i64(o, "width").map(Int.init); h = i64(o, "height").map(Int.init); dur = i64(o, "duration").map { $0 * 1000 }; uniq = o["file_unique_id"] as? String }
        case .document:
            if let o = m["document"] as? [String: Any] { size = i64(o, "file_size"); uniq = o["file_unique_id"] as? String }
        }
        return SentMessage(chatId: chat, threadId: i64(m, "message_thread_id"), messageId: i64(m, "message_id") ?? 0,
                           fileUniqueId: uniq, size: size, width: w, height: h, durationMs: dur, kind: kind)
    }

    /// Builds the request and body file for one send. Used by the foreground sender and the background uploader.
    public func buildSend(_ job: SendJob) throws -> (request: URLRequest, bodyFile: URL)? {
        guard let token = tokenProvider() else { return nil }
        let (method, field): (String, String)
        switch job.sendAs { case .photo: (method, field) = ("sendPhoto", "photo"); case .video: (method, field) = ("sendVideo", "video"); case .document: (method, field) = ("sendDocument", "document") }
        var fields = [Multipart.Field(name: "chat_id", value: String(job.chatId)), .init(name: "caption", value: job.caption), .init(name: "disable_notification", value: "true")]
        if let t = job.threadId { fields.append(.init(name: "message_thread_id", value: String(t))) }
        switch job.sendAs {
        case .video:
            fields.append(.init(name: "supports_streaming", value: "true"))
            if let w = job.width { fields.append(.init(name: "width", value: String(w))) }
            if let h = job.height { fields.append(.init(name: "height", value: String(h))) }
            if let d = job.durationMs { fields.append(.init(name: "duration", value: String(d / 1000))) }
        case .document: fields.append(.init(name: "disable_content_type_detection", value: "true"))
        case .photo: break
        }
        let boundary = "tb-" + UUID().uuidString
        let body = scratch.appendingPathComponent("body-\(UUID().uuidString).multipart")
        try Multipart.write(fields: fields, file: .init(name: field, filename: job.displayName, mime: job.mimeType, path: job.path), to: body, boundary: boundary)
        var req = URLRequest(url: URL(string: "\(baseUrl)/bot\(token)/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return (req, body)
    }

    // MARK: calls

    private func form(_ method: String, _ params: [String: String]) async -> ApiResult<Any> {
        guard let token = tokenProvider() else { return .err(.badToken) }
        var req = URLRequest(url: URL(string: "\(baseUrl)/bot\(token)/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "&+=?#")
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: cs) ?? "")" }.joined(separator: "&").data(using: .utf8)
        do {
            let (code, data) = try await transport.send(req, bodyFile: nil, progress: nil)
            return BotApi.parse(httpCode: code, data: data) { $0 }
        } catch { return .err(.network) }
    }

    private func map<T>(_ r: ApiResult<Any>, _ f: (Any) -> T) -> ApiResult<T> {
        switch r { case .ok(let v): return .ok(f(v)); case .err(let e): return .err(e) }
    }
    private static func obj(_ a: Any) -> [String: Any] { a as? [String: Any] ?? [:] }
    private static func i64(_ o: [String: Any], _ k: String) -> Int64? { (o[k] as? NSNumber)?.int64Value }

    public func getMe() async -> ApiResult<BotUser> {
        map(await form("getMe", [:])) { let o = BotApi.obj($0); return BotUser(id: BotApi.i64(o, "id") ?? 0, username: o["username"] as? String ?? "", name: o["first_name"] as? String ?? "") }
    }

    public func getUpdates() async -> ApiResult<[ChatSummary]> {
        map(await form("getUpdates", ["timeout": "0", "limit": "100"])) { any in
            var seen: [(Int64, ChatSummary)] = []
            var migrated = Set<Int64>()
            for u in (any as? [[String: Any]]) ?? [] {
                guard let body = ["message", "my_chat_member", "edited_message", "channel_post"].compactMap({ u[$0] as? [String: Any] }).first,
                      let chat = body["chat"] as? [String: Any], let type = chat["type"] as? String,
                      type == "supergroup" || type == "group", let id = BotApi.i64(chat, "id") else { continue }
                if BotApi.i64(body, "migrate_to_chat_id") != nil { migrated.insert(id) }
                seen.removeAll { $0.0 == id }
                seen.append((id, ChatSummary(id: id, title: chat["title"] as? String ?? "Group", type: type)))
            }
            let superTitles = Set(seen.map { $0.1 }.filter { $0.type == "supergroup" }.map { $0.title })
            return seen.map { $0.1 }.filter { !migrated.contains($0.id) && !($0.type == "group" && superTitles.contains($0.title)) }
        }
    }

    public func getChat(_ id: Int64) async -> ApiResult<ChatInfo> {
        map(await form("getChat", ["chat_id": String(id)])) { let o = BotApi.obj($0); return ChatInfo(id: BotApi.i64(o, "id") ?? id, title: o["title"] as? String ?? "Group", isForum: o["is_forum"] as? Bool ?? false) }
    }
    public func getChatMember(_ chat: Int64, user: Int64) async -> ApiResult<MemberInfo> {
        map(await form("getChatMember", ["chat_id": String(chat), "user_id": String(user)])) { let o = BotApi.obj($0); return MemberInfo(status: o["status"] as? String ?? "", canManageTopics: o["can_manage_topics"] as? Bool ?? false) }
    }
    public func sendMessage(chat: Int64, text: String, threadId: Int64? = nil) async -> ApiResult<Int64> {
        var p = ["chat_id": String(chat), "text": text, "disable_notification": "true"]
        if let t = threadId { p["message_thread_id"] = String(t) }
        return map(await form("sendMessage", p)) { BotApi.i64(BotApi.obj($0), "message_id") ?? 0 }
    }
    public func createForumTopic(chat: Int64, name: String) async -> ApiResult<TopicInfo> {
        map(await form("createForumTopic", ["chat_id": String(chat), "name": String(name.prefix(128))])) { let o = BotApi.obj($0); return TopicInfo(threadId: BotApi.i64(o, "message_thread_id") ?? 0, name: o["name"] as? String ?? name) }
    }

    public func sendFile(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> ApiResult<SentMessage> {
        guard FileManager.default.fileExists(atPath: job.path) else { return .err(.badRequest("file is missing")) }
        guard let built = try? buildSend(job) else { return .err(tokenProvider() == nil ? .badToken : .badRequest("could not prepare the file")) }
        defer { try? FileManager.default.removeItem(at: built.bodyFile) }
        do {
            let (code, data) = try await transport.send(built.request, bodyFile: built.bodyFile, progress: progress)
            return BotApi.parse(httpCode: code, data: data) { BotApi.parseSent($0, kind: job.sendAs, fallbackChat: job.chatId) }
        } catch { return .err(.network) }
    }
}

/// The bot as a `TelegramSender`.
public struct BotSender: TelegramSender {
    let api: BotApi
    public init(api: BotApi) { self.api = api }
    public func send(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> SendResult {
        switch await api.sendFile(job, progress: progress) { case .ok(let m): return .sent(m); case .err(let e): return .failed(e) }
    }
}
