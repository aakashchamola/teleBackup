import Foundation

/// Deletes library items in ONE batch. iOS shows its own confirmation for the whole batch, so the person taps once.
/// Returns the ids that were really deleted (empty if the person said no).
public protocol PhotoDeleter { func deleteBatch(_ assetIds: [String]) async -> Set<String> }
public protocol ReviewNotifier: AnyObject { func reviewWaiting(rule: Rule, review: ReviewRecord) }

public struct CleanOutcome: Equatable {
    public var deleted = 0, denied = 0, reviewsCreated = 0
    public var freedBytes: Int64 = 0
    public var blockedReason: String?
    public var declined = false
}

/// Retention delete. Every delete still goes through `DeleteGate`. On iPhone the delete is always confirmed by the
/// person: a review is made for every batch (not only the first one), and approving it raises the iOS prompt.
public final class Cleaner {
    let store: Store, settings: Settings, events: EventLog, clock: Clock, exporter: AssetExporter, deleter: PhotoDeleter
    public weak var notifier: ReviewNotifier?
    /// The strong check (re-fetch the message as the account) just before a delete. Nil until the account is logged in.
    public var recheck: ((FileRecord) async -> AccountCheck)?
    public static let perRuleCap = 500
    public init(store: Store, settings: Settings, events: EventLog, clock: Clock, exporter: AssetExporter, deleter: PhotoDeleter) {
        self.store = store; self.settings = settings; self.events = events; self.clock = clock; self.exporter = exporter; self.deleter = deleter
    }

    /// Looks for files that are due. Makes or refreshes one waiting review per rule; deletes nothing.
    @discardableResult
    public func prepareReviews() -> Int {
        if let b = settings.deletesBlockedReason { _ = b; return 0 }
        var created = 0
        for rule in store.activeRules() where rule.mode == .uploadAndDelete && rule.enabled {
            let now = clock.now()
            let due = store.verifiedDue(ruleId: rule.id, now: now, limit: Cleaner.perRuleCap)
            if due.isEmpty { if let rv = store.waitingReview(ruleId: rule.id) { dismiss(rv.id) }; continue }
            let total = due.reduce(Int64(0)) { $0 + $1.sizeBytes }
            if var existing = store.waitingReview(ruleId: rule.id) {
                existing.fileCount = due.count; existing.totalBytes = total; store.update(review: existing)
                store.setReview(due.map { $0.id }, existing.id)
            } else {
                let id = store.insert(review: ReviewRecord(ruleId: rule.id, createdAt: now, fileCount: due.count, totalBytes: total))
                store.setReview(due.map { $0.id }, id); created += 1
                events.add(.reviewCreated, "\(rule.name): \(due.count) files are ready to delete. Check them first.", ruleId: rule.id)
                if let rv = store.review(id: id) { notifier?.reviewWaiting(rule: rule, review: rv) }
            }
        }
        return created
    }

    public func approve(_ reviewId: Int64) {
        guard var rv = store.review(id: reviewId), rv.status == .waiting else { return }
        rv.status = .approved; rv.decidedAt = clock.now(); store.update(review: rv)
        events.add(.reviewApproved, "Delete approved for \(rv.fileCount) files", ruleId: rv.ruleId)
    }
    public func dismiss(_ reviewId: Int64) {
        guard var rv = store.review(id: reviewId) else { return }
        rv.status = .dismissed; rv.decidedAt = clock.now(); store.update(review: rv)
        store.setReview(store.inReview(reviewId).map { $0.id }, nil)
    }

    /// Runs the gate on every file of an approved review, then deletes the allowed ones in one batch.
    public func deleteApproved(reviewId: Int64) async -> CleanOutcome {
        var out = CleanOutcome()
        if let b = settings.deletesBlockedReason { out.blockedReason = b; return out }
        guard let rv = store.review(id: reviewId), rv.status == .approved, let rule = store.rule(id: rv.ruleId) else { return out }
        var allowed: [(FileRecord, DeletePermit)] = []
        for f in store.inReview(reviewId) where f.state == .verified {
            let now = clock.now()
            let account: AccountCheck = (settings.accountState == .ready ? await recheck?(f) : nil) ?? .notReady
            switch DeleteGate.check(file: f, rule: rule, deletesBlockedReason: settings.deletesBlockedReason, disk: exporter.facts(f.path), now: now,
                                    inApprovedReview: true, account: account, allowBotOnly: settings.allowBotOnlyDelete) {
            case .allowed(let p): allowed.append((f, p))
            case .denied(let why):
                out.denied += 1
                switch why {
                case .fileChanged: _ = try? store.apply(f.id, .changed, now: now)
                case .fileMissing: _ = try? store.apply(f.id, .vanished, now: now)
                default: break
                }
                events.add(.deleteDenied, "\(f.displayName) was not deleted (\(why))", ruleId: rule.id, fileId: f.id)
            }
        }
        guard !allowed.isEmpty else { return out }
        let deleted = await deleter.deleteBatch(allowed.map { $0.0.path })
        if deleted.isEmpty { out.declined = true; return out }
        for (f, permit) in allowed where deleted.contains(f.path) {
            if (try? store.apply(f.id, .deletedByCleaner(permit, freedBytes: f.sizeBytes), now: clock.now())) != nil {
                out.deleted += 1; out.freedBytes += f.sizeBytes
                events.add(.deleted, "\(f.displayName) deleted from the phone", ruleId: rule.id, fileId: f.id, bytes: f.sizeBytes)
            }
        }
        settings.lastCleanAt = clock.now()
        return out
    }
}
