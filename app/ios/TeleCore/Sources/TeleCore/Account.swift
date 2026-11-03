import Foundation

/// Where the TDLib login is, in our words (a thin copy of TDLib's authorization state).
public enum TdAuth: Equatable {
    case closed, waitParams, waitPhone
    case waitCode(sentTo: String?)
    case waitPassword(hint: String?)
    case waitOther(String)
    case ready(name: String, phoneMasked: String?)
    case loggedOut
}

public struct TdParams {
    public var apiId: Int, apiHash: String, databaseDir: String, filesDir: String, databaseKey: String
    public init(apiId: Int, apiHash: String, databaseDir: String, filesDir: String, databaseKey: String) {
        self.apiId = apiId; self.apiHash = apiHash; self.databaseDir = databaseDir; self.filesDir = filesDir; self.databaseKey = databaseKey
    }
}
public enum TdStep: Equatable { case ok, rejected(String), network }
public enum TdFetch: Equatable { case found(SentMessage), notFound, unavailable }

/// The only thing the app knows about TDLib. The real one is in the TeleTD package; tests use a fake.
/// Message ids in and out are Bot API ids; the gateway does the 20-bit shift (see `TdIds`).
public protocol TdGateway: AnyObject {
    var auth: TdAuth { get }
    var onAuth: ((TdAuth) -> Void)? { get set }
    func open(_ params: TdParams) async
    func submitPhone(_ phone: String) async -> TdStep
    func submitCode(_ code: String) async -> TdStep
    func submitPassword(_ password: String) async -> TdStep
    func resendCode() async -> TdStep
    func send(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> SendResult
    func sendAlbum(_ jobs: [SendJob], progress: @escaping (Int64, Int64) -> Void) async -> AlbumResult
    func fetch(chatId: Int64, botApiMessageId: Int64) async -> TdFetch
    func logOut() async
    func close()
}

public enum TdIds {
    public static func toTdlib(_ botApiMessageId: Int64) -> Int64 { botApiMessageId << 20 }
    public static func fromTdlib(_ tdlibMessageId: Int64) -> Int64 { tdlibMessageId >> 20 }
}

/// Pure helpers for the TDLib adapter.
public enum TdErrors {
    private static func firstInt(_ pattern: String, in text: String) -> Int64? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int64(text[r])
    }

    public static func forSend(code: Int, message: String) -> TgError {
        let m = message.uppercased()
        switch true {
        case code == 429 || m.hasPrefix("FLOOD_WAIT") || m.contains("TOO MANY REQUESTS"):
            return .floodWait(seconds: firstInt("retry after (\\d+)", in: message) ?? firstInt("FLOOD_WAIT_(\\d+)", in: m) ?? 30)
        case code == 401 || m.contains("AUTH_KEY") || m.contains("SESSION_REVOKED") || m.contains("USER_DEACTIVATED"): return .accountLoggedOut
        case m.contains("TOPIC_DELETED") || m.contains("TOPIC_ID_INVALID") || m.contains("MESSAGE_THREAD_INVALID") || m.contains("TOPIC_CLOSED"): return .topicMissing
        case m.contains("CHAT_WRITE_FORBIDDEN") || m.contains("CHAT_ADMIN_REQUIRED") || m.contains("USER_BANNED_IN_CHANNEL") || code == 403: return .forbidden(message)
        case m.contains("FILE_PARTS_INVALID") || m.contains("FILE_TOO_BIG") || m.contains("FILE_SIZE_EXCEEDED"): return .tooLarge
        case (500...599).contains(code): return .server(code: code)
        case code == 400: return .badRequest(message)
        default: return .server(code: code)
        }
    }

    /// What the login screens say for a rejected step. Never shows Telegram's raw text.
    public static func forLogin(code: Int, message: String) -> String {
        let m = message.uppercased()
        switch true {
        case m.contains("PHONE_NUMBER_INVALID") || m.contains("PHONE_NUMBER_BANNED"): return "That phone number is not valid."
        case m.contains("PHONE_CODE_INVALID") || m.contains("CODE_INVALID"): return "That code is not right."
        case m.contains("PHONE_CODE_EXPIRED") || m.contains("CODE_EXPIRED"): return "That code has expired. Ask for a new one."
        case m.contains("PASSWORD_HASH_INVALID") || m.contains("PASSWORD_INVALID"): return "That password is not right."
        case code == 429 || m.contains("FLOOD") || m.contains("TOO MANY"):
            if let s = firstInt("retry after (\\d+)", in: message) ?? firstInt("FLOOD_WAIT_(\\d+)", in: m) { return "Telegram says wait \(s) seconds, then try again." }
            return "Too many tries. Wait a few minutes and try again."
        case m.contains("API_ID_INVALID") || m.contains("API_ID_PUBLISHED_FLOOD"): return "Telegram did not accept that api_id and api_hash."
        default: return "Telegram did not accept that. Try again."
        }
    }

    public static func maskPhone(_ phone: String?) -> String? {
        let d = (phone ?? "").filter { $0.isNumber }
        return d.count < 4 ? nil : "+•• ••••• ••" + d.suffix(3)
    }
}

public protocol SecretStore { func get(_ key: String) -> String?; func put(_ key: String, _ value: String?) }

public struct AccountSnapshot: Equatable {
    public enum Step { case none, waitParams, waitPhone, waitCode, waitPassword, waitOther, ready, expired }
    public var step: Step
    public var name: String?, phoneMasked: String?, codeSentTo: String?, passwordHint: String?, lastError: String?
    public init(_ step: Step, name: String? = nil, phoneMasked: String? = nil, codeSentTo: String? = nil, passwordHint: String? = nil, lastError: String? = nil) {
        self.step = step; self.name = name; self.phoneMasked = phoneMasked; self.codeSentTo = codeSentTo; self.passwordHint = passwordHint; self.lastError = lastError
    }
}

/// The account login and the one place that opens and closes the TDLib client. Keeps `settings.accountState` true:
/// ready while logged in, expired when a session that worked ended. api id/hash and the database key live in the secret store.
public final class AccountAuth {
    public enum Readiness { case ready, notLoggedIn, offline }
    let gateway: TdGateway, settings: Settings, secrets: SecretStore, folders: () -> (db: String, files: String)
    let settleMs: Int
    private var lastError: String?
    private var opened = false
    public var onChange: (() -> Void)?

    public init(gateway: TdGateway, settings: Settings, secrets: SecretStore, folders: @escaping () -> (db: String, files: String), settleMs: Int = 20_000) {
        self.gateway = gateway; self.settings = settings; self.secrets = secrets; self.folders = folders; self.settleMs = settleMs
        gateway.onAuth = { [weak self] a in self?.onAuth(a) }
    }

    private func onAuth(_ a: TdAuth) {
        switch a {
        case .ready(let name, _): settings.accountState = .ready; settings.accountName = name; lastError = nil
        case .loggedOut: if settings.accountState == .ready { settings.accountState = .expired }
        default: break
        }
        onChange?()
    }

    public func snapshot() -> AccountSnapshot {
        let saved = settings.accountState
        switch gateway.auth {
        case .waitParams: return AccountSnapshot(.waitParams, lastError: lastError)
        case .waitPhone: return AccountSnapshot(saved == .expired ? .expired : .waitPhone, lastError: lastError)
        case .waitCode(let s): return AccountSnapshot(.waitCode, codeSentTo: s, lastError: lastError)
        case .waitPassword(let h): return AccountSnapshot(.waitPassword, passwordHint: h, lastError: lastError)
        case .waitOther(let w): return AccountSnapshot(.waitOther, lastError: lastError ?? w)
        case .ready(let n, let p): return AccountSnapshot(.ready, name: n, phoneMasked: p)
        case .closed, .loggedOut:
            switch saved {
            case .ready: return AccountSnapshot(.ready, name: settings.accountName)
            case .expired: return AccountSnapshot(.expired, name: settings.accountName, lastError: lastError)
            case .none: return AccountSnapshot(.none, lastError: lastError)
            }
        }
    }

    public func start(apiId: Int64, apiHash: String) async -> AccountSnapshot {
        let hash = apiHash.trimmingCharacters(in: .whitespaces)
        guard apiId > 0, apiId <= Int64(Int32.max), hash.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else {
            lastError = "That api_id or api_hash does not look right. Copy both again from my.telegram.org."; return snapshot()
        }
        secrets.put("td.apiId", String(apiId)); secrets.put("td.apiHash", hash); lastError = nil
        await open(); await settle()
        return snapshot()
    }

    private func open() async {
        guard let id = secrets.get("td.apiId").flatMap(Int.init), let hash = secrets.get("td.apiHash") else { lastError = "Enter the api_id and api_hash first."; return }
        let key = secrets.get("td.key") ?? { let k = Self.randomKey(); secrets.put("td.key", k); return k }()
        let f = folders()
        await gateway.open(TdParams(apiId: id, apiHash: hash, databaseDir: f.db, filesDir: f.files, databaseKey: key))
        opened = true
    }

    private func settle(_ ms: Int? = nil) async {
        let deadline = Date().addingTimeInterval(Double(ms ?? settleMs) / 1000)
        while Date() < deadline {
            switch gateway.auth { case .closed, .waitParams: try? await Task.sleep(nanoseconds: 100_000_000); default: return }
        }
    }

    private func step(_ r: TdStep) -> AccountSnapshot {
        switch r { case .ok: lastError = nil; case .rejected(let m): lastError = m; case .network: lastError = "No internet. Try again when online." }
        return snapshot()
    }

    public func phone(_ phone: String) async -> AccountSnapshot {
        let p = phone.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard p.range(of: "^\\+?[0-9]{7,15}$", options: .regularExpression) != nil else { lastError = "Type the phone number with the country code, like +91 98765 43210."; return snapshot() }
        return step(await gateway.submitPhone(p.hasPrefix("+") ? p : "+" + p))
    }
    public func code(_ c: String) async -> AccountSnapshot { step(await gateway.submitCode(c.replacingOccurrences(of: " ", with: ""))) }
    public func password(_ p: String) async -> AccountSnapshot { step(await gateway.submitPassword(p)) }
    public func resendCode() async -> AccountSnapshot { step(await gateway.resendCode()) }

    public func logout() async {
        if !opened { await open() }
        await gateway.logOut(); gateway.close(); opened = false
        secrets.put("td.key", nil); secrets.put("td.apiId", nil); secrets.put("td.apiHash", nil)
        settings.accountState = .none; settings.accountName = nil; lastError = nil
    }

    /// Makes sure the saved session is open and ready.
    public func ensureReady() async -> Readiness {
        if settings.accountState == .none { return .notLoggedIn }
        if case .ready = gateway.auth {} else {
            if !opened || gateway.auth == .closed { await open() }
            await settle()
        }
        switch gateway.auth {
        case .ready: return .ready
        case .waitPhone, .loggedOut, .waitCode, .waitPassword, .waitOther: settings.accountState = .expired; return .notLoggedIn
        default: return .offline
        }
    }

    public func release() { gateway.close(); opened = false }

    public static func randomKey() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
}

/// Sends as the logged-in account (files over the 50 MB the bot can take).
public final class AccountSender: TelegramSender {
    let auth: AccountAuth, gateway: TdGateway
    public init(auth: AccountAuth, gateway: TdGateway) { self.auth = auth; self.gateway = gateway }
    public func send(_ job: SendJob, progress: @escaping (Int64, Int64) -> Void) async -> SendResult {
        switch await auth.ensureReady() {
        case .ready: return await gateway.send(job, progress: progress)
        case .notLoggedIn: return .failed(.accountLoggedOut)
        case .offline: return .failed(.network)
        }
    }
    public func sendAlbum(_ jobs: [SendJob], progress: @escaping (Int64, Int64) -> Void) async -> AlbumResult {
        switch await auth.ensureReady() {
        case .ready: return await gateway.sendAlbum(jobs, progress: progress)
        case .notLoggedIn: return .failed(.accountLoggedOut)
        case .offline: return .failed(.network)
        }
    }
}

/// The strong check before a delete: ask Telegram for the message again, as the account, and compare it with what we stored.
public final class AccountRecheck {
    let auth: AccountAuth, gateway: TdGateway
    public init(auth: AccountAuth, gateway: TdGateway) { self.auth = auth; self.gateway = gateway }
    public func recheck(_ f: FileRecord) async -> AccountCheck {
        guard let chat = f.tgChatId, let msg = f.tgMessageId else { return .notFound }
        switch await auth.ensureReady() { case .notLoggedIn: return .notReady; case .offline: return .unavailable; case .ready: break }
        switch await gateway.fetch(chatId: chat, botApiMessageId: msg) {
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        case .found(let m):
            let sameKind = f.sendAs == nil || m.kind == f.sendAs
            let sizeOk = m.kind == .photo ? true : (f.tgSize != nil && m.size == f.tgSize)   // photos are re-encoded: the file id is what counts
            let idOk = f.tgFileUniqueId == nil || m.fileUniqueId == nil || f.tgFileUniqueId == m.fileUniqueId
            return sameKind && sizeOk && idOk ? .ok : .mismatch
        }
    }
}
