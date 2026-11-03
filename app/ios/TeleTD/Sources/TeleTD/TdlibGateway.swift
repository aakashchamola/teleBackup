import Foundation
import TeleCore

/// The real `TdGateway`: TDLib behind the seam. The database is encrypted with a key from the Keychain and lives in Application Support
/// (excluded from backups). TDLib runs in its own threads; this class turns its answers into async calls.
public final class TdlibGateway: TdGateway {
    public private(set) var auth: TdAuth = .closed { didSet { onAuth?(auth) } }
    public var onAuth: ((TdAuth) -> Void)?

    private let appVersion: String, deviceModel: String, systemVersion: String
    private let td = TdJson.shared
    private var client: Int32?
    private var params: TdParams?
    private var loggingOut = false
    private let lock = NSRecursiveLock()

    private final class Upload { let total: Int64; let progress: (Int64, Int64) -> Void; init(_ t: Int64, _ p: @escaping (Int64, Int64) -> Void) { total = t; progress = p } }
    private var uploadsByFile: [Int: Upload] = [:]
    private var sendWaiters: [Int64: CheckedContinuation<[String: Any], Never>] = [:]
    private var earlyResults: [Int64: [String: Any]] = [:]

    public init(appVersion: String, deviceModel: String, systemVersion: String) {
        self.appVersion = appVersion; self.deviceModel = deviceModel; self.systemVersion = systemVersion
    }

    // MARK: life of the client

    public func open(_ params: TdParams) async {
        lock.lock(); defer { lock.unlock() }
        if client != nil { return }
        self.params = params; loggingOut = false
        try? FileManager.default.createDirectory(atPath: params.databaseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: params.filesDir, withIntermediateDirectories: true)
        for p in [params.databaseDir, params.filesDir] { var u = URL(fileURLWithPath: p); var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v) }
        auth = .waitParams
        client = td.createClient { [weak self] in self?.onUpdate($0) }
    }

    public func close() { if let c = client { td.send(c, ["@type": "close"]) } }

    public func logOut() async { guard let c = client else { return }; loggingOut = true; td.send(c, ["@type": "logOut"]) }

    // MARK: updates

    private func onUpdate(_ o: [String: Any]) {
        switch o["@type"] as? String {
        case "updateAuthorizationState": if let s = o["authorization_state"] as? [String: Any] { onAuthState(s) }
        case "updateFile":
            if let f = o["file"] as? [String: Any], let id = (f["id"] as? NSNumber)?.intValue {
                lock.lock(); let u = uploadsByFile[id]; lock.unlock()
                if let u = u { let sent = ((f["remote"] as? [String: Any])?["uploaded_size"] as? NSNumber)?.int64Value ?? 0; u.progress(min(sent, u.total), u.total) }
            }
        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            guard let old = (o["old_message_id"] as? NSNumber)?.int64Value else { return }
            lock.lock()
            if let w = sendWaiters.removeValue(forKey: old) { lock.unlock(); w.resume(returning: o) } else { earlyResults[old] = o; lock.unlock() }
        default: break
        }
    }

    private func onAuthState(_ s: [String: Any]) {
        switch s["@type"] as? String {
        case "authorizationStateWaitTdlibParameters": sendParameters()
        case "authorizationStateWaitPhoneNumber": auth = .waitPhone
        case "authorizationStateWaitCode": auth = .waitCode(sentTo: Self.sentTo((s["code_info"] as? [String: Any])?["type"] as? [String: Any]))
        case "authorizationStateWaitPassword":
            let h = s["password_hint"] as? String; auth = .waitPassword(hint: (h ?? "").isEmpty ? nil : h)
        case "authorizationStateWaitEmailAddress", "authorizationStateWaitEmailCode":
            auth = .waitOther("Telegram wants an e-mail login for this account. That is not supported yet; turn it off in Telegram and try again.")
        case "authorizationStateWaitRegistration": auth = .waitOther("This phone number has no Telegram account yet. Make one in the Telegram app first.")
        case "authorizationStateWaitOtherDeviceConfirmation", "authorizationStatePremiumPurchase", "authorizationStateWaitPremiumPurchase":
            auth = .waitOther("Telegram wants a confirmation this app cannot give.")
        case "authorizationStateReady": Task { await readyWithName() }
        case "authorizationStateLoggingOut": loggingOut = true
        case "authorizationStateClosed":
            lock.lock(); if let c = client { td.removeClient(c) }; client = nil; uploadsByFile.removeAll(); lock.unlock()
            auth = loggingOut ? .loggedOut : .closed; loggingOut = false
        default: break
        }
    }

    private static func sentTo(_ t: [String: Any]?) -> String {
        switch t?["@type"] as? String {
        case "authenticationCodeTypeTelegramMessage": return "Telegram app"
        case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase": return "SMS"
        case "authenticationCodeTypeCall", "authenticationCodeTypeFlashCall", "authenticationCodeTypeMissedCall": return "a phone call"
        default: return "Telegram"
        }
    }

    private func sendParameters() {
        guard let p = params, let c = client else { return }
        Task {
            let r = await td.request(c, [
                "@type": "setTdlibParameters", "use_test_dc": false, "database_directory": p.databaseDir, "files_directory": p.filesDir,
                "database_encryption_key": Data(p.databaseKey.utf8).base64EncodedString(),
                "use_file_database": true, "use_chat_info_database": true, "use_message_database": false, "use_secret_chats": false,
                "api_id": p.apiId, "api_hash": p.apiHash, "system_language_code": "en", "device_model": deviceModel,
                "system_version": systemVersion, "application_version": appVersion,
            ])
            if r["@type"] as? String == "error" { auth = .waitOther(TdErrors.forLogin(code: Self.code(r), message: Self.msg(r))) }
        }
    }

    private func readyWithName() async {
        guard let c = client else { auth = .ready(name: "Telegram account", phoneMasked: nil); return }
        let u = await td.request(c, ["@type": "getMe"])
        let name = [u["first_name"] as? String, u["last_name"] as? String].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        auth = .ready(name: name.isEmpty ? "Telegram account" : name, phoneMasked: TdErrors.maskPhone(u["phone_number"] as? String))
    }

    // MARK: login steps

    private static func code(_ r: [String: Any]) -> Int { (r["code"] as? NSNumber)?.intValue ?? 0 }
    private static func msg(_ r: [String: Any]) -> String { r["message"] as? String ?? "" }
    private func step(_ obj: [String: Any]) async -> TdStep {
        guard let c = client else { return .network }
        let r = await td.request(c, obj)
        if r["@type"] as? String == "error" {
            if Self.code(r) == 500 && Self.msg(r).lowercased().contains("network") { return .network }
            return .rejected(TdErrors.forLogin(code: Self.code(r), message: Self.msg(r)))
        }
        return .ok
    }
    public func submitPhone(_ phone: String) async -> TdStep { await step(["@type": "setAuthenticationPhoneNumber", "phone_number": phone, "settings": ["@type": "phoneNumberAuthenticationSettings"]]) }
    public func submitCode(_ code: String) async -> TdStep { await step(["@type": "checkAuthenticationCode", "code": code]) }
    public func submitPassword(_ password: String) async -> TdStep { await step(["@type": "checkAuthenticationPassword", "password": password]) }
    public func resendCode() async -> TdStep { await step(["@type": "resendAuthenticationCode", "reason": ["@type": "resendCodeReasonUserRequest"]]) }

    // MARK: sending

    /// TDLib only knows a chat it has loaded; ask for the chat list first when it does not know this one yet.
    private func knowChat(_ chatId: Int64) async -> Bool {
        guard let c = client else { return false }
        if (await td.request(c, ["@type": "getChat", "chat_id": chatId]))["@type"] as? String == "chat" { return true }
        _ = await td.request(c, ["@type": "getChats", "chat_list": ["@type": "chatListMain"], "limit": 200])
        return (await td.request(c, ["@type": "getChat", "chat_id": chatId]))["@type"] as? String == "chat"
    }

    private func content(_ job: SendJob) -> [String: Any]? {
        let file: [String: Any] = ["@type": "inputFileLocal", "path": job.path]
        let caption: [String: Any] = ["@type": "formattedText", "text": job.caption, "entities": []]
        switch job.sendAs {
        case .document:
            return ["@type": "inputMessageDocument", "caption": caption,
                    "document": ["@type": "inputDocument", "document": file, "disable_content_type_detection": true]]
        case .video:
            return ["@type": "inputMessageVideo", "caption": caption, "show_caption_above_media": false, "has_spoiler": false,
                    "video": ["@type": "inputVideo", "video": file, "duration": Int((job.durationMs ?? 0) / 1000), "width": job.width ?? 0,
                              "height": job.height ?? 0, "supports_streaming": true, "added_sticker_file_ids": [Int]()]]
        case .photo: return nil   // photos go through the bot
        }
    }

    private static func fileOf(_ content: [String: Any]?) -> [String: Any]? {
        switch content?["@type"] as? String {
        case "messageDocument": return (content?["document"] as? [String: Any])?["document"] as? [String: Any]
        case "messageVideo": return (content?["video"] as? [String: Any])?["video"] as? [String: Any]
        case "messagePhoto":
            let sizes = (content?["photo"] as? [String: Any])?["sizes"] as? [[String: Any]] ?? []
            return sizes.max { (($0["width"] as? Int) ?? 0) * (($0["height"] as? Int) ?? 0) < (($1["width"] as? Int) ?? 0) * (($1["height"] as? Int) ?? 0) }?["photo"] as? [String: Any]
        default: return nil
        }
    }

    /// A TDLib message as the Bot API form of what we sent (ids shifted back, sizes read from the content).
    static func toSent(_ m: [String: Any]) -> SentMessage? {
        guard let chat = (m["chat_id"] as? NSNumber)?.int64Value, let rawId = (m["id"] as? NSNumber)?.int64Value else { return nil }
        let thread = ((m["topic_id"] as? [String: Any])?["forum_topic_id"] as? NSNumber)?.int64Value
        let id = TdIds.fromTdlib(rawId)
        let c = m["content"] as? [String: Any]
        func size(_ f: [String: Any]?) -> Int64? { (f?["size"] as? NSNumber)?.int64Value }
        func uid(_ f: [String: Any]?) -> String? { (f?["remote"] as? [String: Any])?["unique_id"] as? String }
        switch c?["@type"] as? String {
        case "messageDocument":
            let f = (c?["document"] as? [String: Any])?["document"] as? [String: Any]
            return SentMessage(chatId: chat, threadId: thread, messageId: id, fileUniqueId: uid(f), size: size(f), kind: .document)
        case "messageVideo":
            let v = c?["video"] as? [String: Any]; let f = v?["video"] as? [String: Any]
            return SentMessage(chatId: chat, threadId: thread, messageId: id, fileUniqueId: uid(f), size: size(f), width: (v?["width"] as? NSNumber)?.intValue,
                               height: (v?["height"] as? NSNumber)?.intValue, durationMs: ((v?["duration"] as? NSNumber)?.int64Value).map { $0 * 1000 }, kind: .video)
        case "messagePhoto":
            guard let f = fileOf(c) else { return nil }
            let sizes = (c?["photo"] as? [String: Any])?["sizes"] as? [[String: Any]] ?? []
            let big = sizes.max { (($0["width"] as? Int) ?? 0) * (($0["height"] as? Int) ?? 0) < (($1["width"] as? Int) ?? 0) * (($1["height"] as? Int) ?? 0) }
            let s = size(f); return SentMessage(chatId: chat, threadId: thread, messageId: id, fileUniqueId: uid(f), size: (s ?? 0) > 0 ? s : nil,
                                                width: (big?["width"] as? NSNumber)?.intValue, height: (big?["height"] as? NSNumber)?.intValue, kind: .photo)
        default: return nil
        }
    }

    public func send(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> SendResult {
        guard let c = client else { return .failed(.accountLoggedOut) }
        guard await knowChat(job.chatId) else { return .failed(.forbidden("the account cannot see the group; add the account to it")) }
        guard let body = content(job) else { return .failed(.badRequest("photos go through the bot")) }
        var req: [String: Any] = ["@type": "sendMessage", "chat_id": job.chatId, "input_message_content": body,
                                  "options": ["@type": "messageSendOptions", "disable_notification": true, "from_background": true]]
        if let t = job.threadId { req["topic_id"] = ["@type": "messageTopicForum", "forum_topic_id": t] }
        let first = await td.request(c, req)
        if first["@type"] as? String == "error" { return .failed(TdErrors.forSend(code: Self.code(first), message: Self.msg(first))) }
        guard let pendingId = (first["id"] as? NSNumber)?.int64Value else { return .failed(.network) }
        let fileId = (Self.fileOf(first["content"] as? [String: Any])?["id"] as? NSNumber)?.intValue
        if let f = fileId { lock.lock(); uploadsByFile[f] = Upload(job.sizeBytes, progress); lock.unlock() }
        defer { if let f = fileId { lock.lock(); uploadsByFile[f] = nil; lock.unlock() } }

        let result: [String: Any] = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
                lock.lock()
                if let early = earlyResults.removeValue(forKey: pendingId) { lock.unlock(); cont.resume(returning: early) }
                else { sendWaiters[pendingId] = cont; lock.unlock() }
            }
        } onCancel: { [weak self] in
            // cancelled while sending: stop the upload and drop the half-sent message
            guard let self = self, let c = self.client else { return }
            self.td.send(c, ["@type": "deleteMessages", "chat_id": job.chatId, "message_ids": [pendingId], "revoke": true])
            self.lock.lock(); let w = self.sendWaiters.removeValue(forKey: pendingId); self.lock.unlock()
            w?.resume(returning: ["@type": "updateMessageSendFailed", "error": ["code": 500, "message": "network cancelled"]])
        }
        if result["@type"] as? String == "updateMessageSendFailed" {
            let e = result["error"] as? [String: Any] ?? [:]
            if Self.msg(e) == "network cancelled" { return .failed(.network) }
            return .failed(TdErrors.forSend(code: Self.code(e), message: Self.msg(e)))
        }
        guard let msg = result["message"] as? [String: Any], let sent = Self.toSent(msg) else { return .failed(.badRequest("Telegram answered with something that is not the file")) }
        return .sent(sent)
    }

    public func sendAlbum(_ jobs: [SendJob], progress: @escaping (Int64, Int64) -> Void) async -> AlbumResult {
        guard let c = client, let first = jobs.first else { return .failed(.accountLoggedOut) }
        guard await knowChat(first.chatId) else { return .failed(.forbidden("the account cannot see the group; add the account to it")) }
        var contents: [[String: Any]] = []
        for j in jobs { guard let b = content(j) else { return .failed(.badRequest("photos go through the bot")) }; contents.append(b) }
        var req: [String: Any] = ["@type": "sendMessageAlbum", "chat_id": first.chatId, "input_message_contents": contents,
                                  "options": ["@type": "messageSendOptions", "disable_notification": true, "from_background": true]]
        if let t = first.threadId { req["topic_id"] = ["@type": "messageTopicForum", "forum_topic_id": t] }
        let answer = await td.request(c, req)
        if answer["@type"] as? String == "error" { return .failed(TdErrors.forSend(code: Self.code(answer), message: Self.msg(answer))) }
        let pending = (answer["messages"] as? [[String: Any]]) ?? []
        guard pending.count == jobs.count else { return .failed(.badRequest("Telegram made \(pending.count) messages for \(jobs.count) files")) }
        let total = jobs.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let ids = pending.compactMap { ($0["id"] as? NSNumber)?.int64Value }
        guard ids.count == pending.count else { return .failed(.network) }
        var fileIds: [Int] = []; var before: Int64 = 0
        for (i, m) in pending.enumerated() {
            let offset = before; before += jobs[i].sizeBytes
            if let f = (Self.fileOf(m["content"] as? [String: Any])?["id"] as? NSNumber)?.intValue {
                fileIds.append(f); lock.lock(); uploadsByFile[f] = Upload(jobs[i].sizeBytes) { s, _ in progress(offset + s, total) }; lock.unlock()
            }
        }
        defer { lock.lock(); for f in fileIds { uploadsByFile[f] = nil }; lock.unlock() }

        // wait for every part; the first failure stops the rest
        var results: [Int64: [String: Any]] = [:]
        for id in ids {
            let r: [String: Any] = await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
                    lock.lock()
                    if let early = earlyResults.removeValue(forKey: id) { lock.unlock(); cont.resume(returning: early) }
                    else { sendWaiters[id] = cont; lock.unlock() }
                }
            } onCancel: { [weak self] in
                guard let self = self else { return }
                self.lock.lock(); let w = self.sendWaiters.removeValue(forKey: id); self.lock.unlock()
                w?.resume(returning: ["@type": "updateMessageSendFailed", "error": ["code": 500, "message": "network cancelled"]])
            }
            results[id] = r
            if r["@type"] as? String == "updateMessageSendFailed" { break }
        }
        let failed = results.values.first { $0["@type"] as? String == "updateMessageSendFailed" }
        if results.count < ids.count || failed != nil {   // half-way: drop what was not sent, so a retry starts clean
            lock.lock(); for id in ids { sendWaiters[id] = nil; earlyResults[id] = nil }; lock.unlock()
            td.send(c, ["@type": "deleteMessages", "chat_id": first.chatId, "message_ids": ids, "revoke": true])
            let e = failed?["error"] as? [String: Any] ?? [:]
            if Self.msg(e) == "network cancelled" || failed == nil { return .failed(.network) }
            return .failed(TdErrors.forSend(code: Self.code(e), message: Self.msg(e)))
        }
        var sent: [SentMessage] = []
        for id in ids {
            guard let msg = results[id]?["message"] as? [String: Any], let s = Self.toSent(msg) else { return .failed(.badRequest("Telegram answered with something that is not the file")) }
            sent.append(s)
        }
        return .sent(sent)
    }

    // MARK: fetching again

    public func fetch(chatId: Int64, botApiMessageId: Int64) async -> TdFetch {
        guard let c = client, await knowChat(chatId) else { return .unavailable }
        let r = await td.request(c, ["@type": "getMessage", "chat_id": chatId, "message_id": TdIds.toTdlib(botApiMessageId)])
        if r["@type"] as? String == "error" { return Self.code(r) == 404 || Self.msg(r).lowercased().contains("not found") ? .notFound : .unavailable }
        return Self.toSent(r).map { .found($0) } ?? .notFound
    }
}
