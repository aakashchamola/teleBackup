import Foundation

/// After a fresh install (new Mac, new Apple ID, new bundle ID) the phone has no record of what was already backed up.
/// This reads the group's history through the Telegram account, remembers which photos and videos are there
/// (by the name and time in each caption), and lets the scanner skip them. It never uploads and never deletes anything.
public final class HistoryRestorer {
    public static let pageSize = 100, maxPages = 2000
    let store: Store, gateway: TdGateway, auth: AccountAuth
    public init(store: Store, gateway: TdGateway, auth: AccountAuth) { self.store = store; self.gateway = gateway; self.auth = auth }

    static func doneKey(_ chat: Int64) -> String { "restore.done.\(chat)" }
    public func needed(chatId: Int64) -> Bool { store.setting(Self.doneKey(chatId)) == nil }

    /// Files already queued before the history was read (a scan can run first): the ones found in Telegram are not uploaded again.
    @discardableResult
    func markWaitingFiles() -> Int {
        var n = 0
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for rule in store.allRules() {
            for f in store.byRuleAndStates(rule.id, [.queued, .failed, .skipped]) where store.isRestored(Caption.key(displayName: f.displayName, takenAt: f.takenAt)) {
                if (try? store.apply(f.id, .ignore, now: now)) != nil {
                    var u = f; u.lastError = "Already in Telegram (found when reconnecting)"; store.updateDetails(u); n += 1
                }
            }
        }
        return n
    }

    /// Returns how many captions were remembered, or nil if it could not finish (it will try again next run).
    @discardableResult
    public func run(chatId: Int64) async -> Int? {
        guard needed(chatId: chatId) else { return 0 }
        guard case .ready = await auth.ensureReady() else { return nil }
        var from: Int64 = 0, found = 0, pages = 0
        while pages < Self.maxPages, !Task.isCancelled {
            pages += 1
            let page = await gateway.history(chatId: chatId, fromTdlibId: from, limit: Self.pageSize)
            if page.failed { return nil }
            let keys = page.captions.compactMap { Caption.key(caption: $0) }
            store.addRestored(keys); found += keys.count
            guard let next = page.oldestId, from == 0 || next < from else { break }
            from = next
        }
        guard !Task.isCancelled else { return nil }
        markWaitingFiles()
        store.put(Self.doneKey(chatId), String(Int(Date().timeIntervalSince1970)))
        return found
    }
}
