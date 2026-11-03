import Foundation

/// Typed settings on top of the key/value table (same keys as the Android app).
public final class Settings {
    let store: Store
    public var debugBuild = false
    public init(_ store: Store) { self.store = store }

    func int64(_ k: String) -> Int64? { store.setting(k).flatMap(Int64.init) }
    func bool(_ k: String, _ d: Bool) -> Bool { store.setting(k).map { $0 == "1" } ?? d }
    func put(_ k: String, _ v: Int64?) { store.put(k, v.map(String.init)) }
    func put(_ k: String, _ v: Bool) { store.put(k, v ? "1" : "0") }

    public var setupDoneAt: Int64? { get { int64("app.setupDoneAt") } set { put("app.setupDoneAt", newValue) } }
    public var setupStep: String { get { store.setting("app.setupStep") ?? "O1" } set { store.put("app.setupStep", newValue) } }
    public var setupDone: Bool { setupDoneAt != nil }
    public var allowMobileData: Bool { get { bool("network.allowMobileData", false) } set { put("network.allowMobileData", newValue) } }
    public var mobileOnceUntilEmpty: Bool { get { bool("network.mobileOnceUntilEmpty", false) } set { put("network.mobileOnceUntilEmpty", newValue) } }
    public var controlState: ControlValue {
        get { store.setting("control.state").flatMap(ControlValue.init) ?? .running }
        set { store.put("control.state", newValue.rawValue) }
    }
    public var delayedUntil: Int64? { get { int64("control.delayedUntil") } set { put("control.delayedUntil", newValue) } }
    public var delayOptionsMinutes: [Int] {
        get { store.setting("control.delayOptionsMinutes").map { $0.split(separator: ",").compactMap { Int($0) } } ?? [120, 300] }
        set { store.put("control.delayOptionsMinutes", newValue.map(String.init).joined(separator: ",")) }
    }
    public static func isValidDelayOptions(_ m: [Int]) -> Bool { (1...4).contains(m.count) && m.allSatisfy { (15...1440).contains($0) } }
    public var defaultRetentionDays: Int { get { Int(int64("rules.defaultRetentionDays") ?? 7) } set { put("rules.defaultRetentionDays", Int64(newValue)) } }
    public var maxAttempts: Int { Int(int64("upload.maxAttempts") ?? 5) }
    public var botMaxBytes: Int64 { int64("upload.botMaxBytes") ?? 52_428_800 }
    public var botPhotoMaxBytes: Int64 { int64("upload.botPhotoMaxBytes") ?? 10_485_760 }
    public var groupByDay: Bool { get { bool("upload.groupByDay", true) } set { put("upload.groupByDay", newValue) } }
    public var documentsTopicId: Int64? { get { int64("documents.topicId") } set { put("documents.topicId", newValue) } }
    public var botId: Int64? { get { int64("telegram.botId") } set { put("telegram.botId", newValue) } }
    public var botUsername: String? { get { store.setting("telegram.botUsername") } set { store.put("telegram.botUsername", newValue) } }
    public var chatId: Int64? { get { int64("telegram.chatId") } set { put("telegram.chatId", newValue) } }
    public var chatTitle: String? { get { store.setting("telegram.chatTitle") } set { store.put("telegram.chatTitle", newValue) } }
    public var accountState: AccountValue { get { store.setting("account.state").flatMap(AccountValue.init) ?? .none } set { store.put("account.state", newValue.rawValue) } }
    public var accountName: String? { get { store.setting("account.displayName") } set { store.put("account.displayName", newValue) } }
    public var botProblem: Bool { get { bool("telegram.botProblem", false) } set { put("telegram.botProblem", newValue) } }
    public var deletesBlockedReason: String? { get { store.setting("deletes.blockedReason") } set { store.put("deletes.blockedReason", newValue) } }
    /// Owner's decision D1: the bot alone may vouch for a delete (the account strong check is not on iPhone yet).
    public var allowBotOnlyDelete: Bool { get { bool("delete.allowBotOnly", true) } set { put("delete.allowBotOnly", newValue) } }
    public var lastScanAt: Int64? { get { int64("stats.lastScanAt") } set { put("stats.lastScanAt", newValue) } }
    public var lastUploadAt: Int64? { get { int64("stats.lastUploadAt") } set { put("stats.lastUploadAt", newValue) } }
    public var lastCleanAt: Int64? { get { int64("stats.lastCleanAt") } set { put("stats.lastCleanAt", newValue) } }
    public var lastStopReason: String? { get { store.setting("stats.lastRunStopReason") } set { store.put("stats.lastRunStopReason", newValue) } }
    public var timeWarp: Bool { get { debugBuild && bool("debug.timeWarp", false) } set { put("debug.timeWarp", newValue) } }
    /// When the free Apple ID signature of this install runs out (set by the app at launch from the provisioning profile).
    public var signatureExpiresAt: Int64? { get { int64("ios.signatureExpiresAt") } set { put("ios.signatureExpiresAt", newValue) } }
}

public final class EventLog {
    let store: Store; let clock: Clock
    public init(_ store: Store, _ clock: Clock) { self.store = store; self.clock = clock }
    public func add(_ kind: EventKind, _ message: String, ruleId: Int64? = nil, fileId: Int64? = nil, bytes: Int64? = nil) {
        store.insert(event: EventRecord(at: clock.now(), kind: kind, message: message, ruleId: ruleId, fileId: fileId, bytes: bytes))
    }
}
