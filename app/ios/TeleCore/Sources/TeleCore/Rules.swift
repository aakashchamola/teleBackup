import Foundation

public struct RuleProblem: Equatable { public var field: String; public var message: String }
public struct RuleException: Error { public var problems: [RuleProblem] }

public enum RuleValidator {
    public static let nameMax = 40
    public static func validate(_ r: Rule, otherActiveNames: [String], folderExists: Bool = true) -> [RuleProblem] {
        var out: [RuleProblem] = []
        let name = r.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { out.append(.init(field: "name", message: "Give the rule a name.")) }
        else if name.count > nameMax { out.append(.init(field: "name", message: "Use \(nameMax) characters or fewer.")) }
        else if otherActiveNames.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }) {
            out.append(.init(field: "name", message: "This name is already used."))
        }
        if r.folderPath.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(field: "folder", message: "Pick an album.")) }
        else if !folderExists { out.append(.init(field: "folder", message: "That album is not on this phone.")) }
        if !(1...365).contains(r.retentionDays) { out.append(.init(field: "retention", message: "Pick 1 to 365 days.")) }
        if r.startMode == .sinceDate && r.startDate == nil { out.append(.init(field: "startDate", message: "Pick a date.")) }
        if r.mode == .uploadAndDelete && r.deleteWarningAcceptedAt == nil { out.append(.init(field: "mode", message: "Turn on delete from the warning first.")) }
        return out
    }
    /// Albums are identified by "smart:<name>" or "album:<localIdentifier>"; there are no paths to tidy on iPhone.
    public static func normalizeFolder(_ p: String) -> String { p.trimmingCharacters(in: .whitespaces) }
}

public enum Retention {
    public static func deleteAfter(verifiedAt: Int64, retentionDays: Int, timeWarp: Bool) -> Int64 {
        verifiedAt + Int64(retentionDays) * (timeWarp ? Time.minute : Time.day)
    }
}

public final class RuleService {
    let store: Store, settings: Settings, events: EventLog, clock: Clock
    public init(store: Store, settings: Settings, events: EventLog, clock: Clock) { self.store = store; self.settings = settings; self.events = events; self.clock = clock }

    public func active() -> [Rule] { store.activeRules() }
    public func get(_ id: Int64) -> Rule? { store.rule(id: id) }

    @discardableResult
    public func save(_ input: Rule, folderExists: Bool = true) throws -> Rule {
        let now = clock.now()
        let old = input.id != 0 ? store.rule(id: input.id) : nil
        var n = input
        n.name = input.name.trimmingCharacters(in: .whitespaces); n.folderPath = RuleValidator.normalizeFolder(input.folderPath)
        let problems = RuleValidator.validate(n, otherActiveNames: store.activeRules().filter { $0.id != input.id }.map { $0.name }, folderExists: folderExists)
        if !problems.isEmpty { throw RuleException(problems: problems) }
        switch n.startMode {
        case .today: n.startDate = (old?.startMode == .today) ? old?.startDate : now
        case .sinceDate: break
        case .everything: n.startDate = nil
        }
        n.updatedAt = now; n.createdAt = old?.createdAt ?? now
        let id: Int64
        if let o = old { id = o.id; n.id = id; n.deletedAt = o.deletedAt; store.update(rule: n) } else { n.id = 0; id = store.insert(rule: n) }
        let saved = store.rule(id: id)!
        if let o = old {
            if o.retentionDays != saved.retentionDays || o.mode != saved.mode { refreshDeleteAfter(saved) }
            if (saved.startDate ?? Int64.min) > (o.startDate ?? Int64.min) { ignoreBeforeStart(saved, now) }
        }
        return saved
    }

    public func setEnabled(_ id: Int64, _ on: Bool) { guard var r = store.rule(id: id) else { return }; r.enabled = on; r.updatedAt = clock.now(); store.update(rule: r) }

    public func softDelete(_ id: Int64) {
        guard var r = store.rule(id: id) else { return }
        let now = clock.now(); r.deletedAt = now; r.enabled = false; r.updatedAt = now; store.update(rule: r)
        for f in store.byRuleAndStates(id, [.queued, .failed, .skipped]) { _ = try? store.apply(f.id, .ignore, now: now) }
    }

    func refreshDeleteAfter(_ rule: Rule) {
        for f in store.verified(ruleId: rule.id) {
            store.setDeleteAfter(f.id, rule.mode == .uploadAndDelete && f.verifiedAt != nil ? Retention.deleteAfter(verifiedAt: f.verifiedAt!, retentionDays: rule.retentionDays, timeWarp: settings.timeWarp) : nil)
        }
    }
    private func ignoreBeforeStart(_ rule: Rule, _ now: Int64) {
        guard let start = rule.startDate else { return }
        for f in store.byRuleAndStates(rule.id, [.queued, .failed, .skipped]) where f.takenAt < start { _ = try? store.apply(f.id, .ignore, now: now) }
    }

    /// Stop all deletes now (docs/HOW_IT_WORKS.md section 12).
    public func stopAllDeletes() {
        let now = clock.now()
        for var r in store.activeRules() {
            r.mode = .uploadOnly; r.dryRun = true; r.deleteWarningAcceptedAt = nil; r.updatedAt = now; store.update(rule: r)
            for f in store.verified(ruleId: r.id) { store.setDeleteAfter(f.id, nil) }
        }
        for var rv in store.allWaitingReviews() {
            rv.status = .dismissed; rv.decidedAt = now; store.update(review: rv)
            store.setReview(store.inReview(rv.id).map { $0.id }, nil)
        }
        events.add(.killSwitch, "Stopped all deletes. Every rule is upload only.")
    }
}

public final class ControlService {
    let settings: Settings, events: EventLog, clock: Clock
    public init(settings: Settings, events: EventLog, clock: Clock) { self.settings = settings; self.events = events; self.clock = clock }
    public func pause() { settings.controlState = .paused; settings.delayedUntil = nil; events.add(.paused, "Paused") }
    public func delay(minutes: Int) {
        precondition((15...1440).contains(minutes))
        settings.controlState = .delayed; settings.delayedUntil = clock.now() + Int64(minutes) * Time.minute
        events.add(.delayed, "Paused for \(Self.describe(minutes))")
    }
    public func resume() { settings.controlState = .running; settings.delayedUntil = nil; events.add(.resumed, "Resumed") }
    public var allowsRun: Bool {
        switch settings.controlState {
        case .running: return true
        case .paused: return false
        case .delayed: return (settings.delayedUntil ?? 0) <= clock.now()
        }
    }
    public static func describe(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60) hour\(m == 60 ? "" : "s")" : "\(m) minutes" }
}
