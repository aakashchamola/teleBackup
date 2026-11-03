import Foundation

/// One photo or video as the library reports it. `path` is the asset's local identifier.
public struct MediaItem: Equatable {
    public var path: String, displayName: String, mimeType: String
    public var sizeBytes: Int64, modifiedAt: Int64
    public var takenAt: Int64?
    public var width: Int?, height: Int?
    public var durationMs: Int64?
    public var kind: FileKind
    public init(path: String, displayName: String, mimeType: String, sizeBytes: Int64, modifiedAt: Int64, takenAt: Int64?, width: Int?, height: Int?, durationMs: Int64?, kind: FileKind) {
        self.path = path; self.displayName = displayName; self.mimeType = mimeType; self.sizeBytes = sizeBytes; self.modifiedAt = modifiedAt
        self.takenAt = takenAt; self.width = width; self.height = height; self.durationMs = durationMs; self.kind = kind
    }
}

/// Where files come from: the Photos library, or a fake in tests.
public protocol MediaSource {
    func list(album: String, types: MediaTypes) -> [MediaItem]
    func exists(_ path: String) -> Bool
    func albumExists(_ album: String) -> Bool
}

public struct ScanResult: Equatable { public var newFiles = 0, updated = 0, changed = 0, gone = 0, tooNew = 0, notIncluded = 0, skippedByRouter = 0 }
public struct BacklogPreview: Equatable { public var count: Int; public var bytes: Int64; public var newestAt: Int64?; public var oldestAt: Int64? }

/// Finds files for a rule and queues them, oldest first (docs/HOW_IT_WORKS.md section 4).
public final class LibraryScanner {
    public static let minAgeMs = 2 * Time.minute
    let source: MediaSource, store: Store, settings: Settings, events: EventLog, clock: Clock
    public init(source: MediaSource, store: Store, settings: Settings, events: EventLog, clock: Clock) {
        self.source = source; self.store = store; self.settings = settings; self.events = events; self.clock = clock
    }
    private func limits() -> RouterLimits { var l = RouterLimits(); l.botMaxBytes = settings.botMaxBytes; l.botPhotoMaxBytes = settings.botPhotoMaxBytes; return l }
    private func taken(_ i: MediaItem) -> Int64 { i.takenAt ?? i.modifiedAt }
    private func included(_ r: Rule, _ t: Int64) -> Bool { r.startMode == .everything || r.startDate == nil || t >= r.startDate! }

    public func preview(_ rule: Rule) -> BacklogPreview {
        let now = clock.now()
        var p = BacklogPreview(count: 0, bytes: 0, newestAt: nil, oldestAt: nil)
        for i in source.list(album: rule.folderPath, types: rule.mediaTypes) where i.modifiedAt <= now - LibraryScanner.minAgeMs {
            let t = taken(i); if !included(rule, t) { continue }
            p.count += 1; p.bytes += i.sizeBytes; p.newestAt = max(p.newestAt ?? t, t); p.oldestAt = min(p.oldestAt ?? t, t)
        }
        return p
    }

    @discardableResult
    public func scan(_ rule: Rule) -> ScanResult {
        var res = ScanResult()
        guard rule.enabled, rule.deletedAt == nil else { return res }
        let now = clock.now()
        var seen = Set<String>(); var pending: [FileRecord] = []
        for i in source.list(album: rule.folderPath, types: rule.mediaTypes).sorted(by: { taken($0) < taken($1) }) {
            seen.insert(i.path)
            if i.modifiedAt > now - LibraryScanner.minAgeMs { res.tooNew += 1; continue }
            let t = taken(i)
            if !included(rule, t) { res.notIncluded += 1; continue }
            if store.find(ruleId: rule.id, path: i.path, size: i.sizeBytes, modifiedAt: i.modifiedAt) != nil { continue }
            let same = store.findByPath(ruleId: rule.id, path: i.path).filter { !$0.state.terminal }
            let decision = Router.decide(sizeBytes: i.sizeBytes, kind: i.kind, uploadAs: rule.uploadAs, displayName: i.displayName, width: i.width, height: i.height, limits: limits())
            if var edited = same.first(where: { [.queued, .failed, .skipped].contains($0.state) }) {
                edited.sizeBytes = i.sizeBytes; edited.modifiedAt = i.modifiedAt; edited.takenAt = t; edited.width = i.width; edited.height = i.height
                edited.durationMs = i.durationMs; edited.sha256 = nil; edited.mimeType = i.mimeType
                if case .go(let route, let sendAs, _, _) = decision { edited.route = route; edited.sendAs = sendAs }
                store.updateDetails(edited)
                if edited.state != .queued { _ = try? store.apply(edited.id, .retryByPerson, now: now) }
                res.updated += 1; continue
            }
            if let v = same.first(where: { $0.state == .verified }) {
                _ = try? store.apply(v.id, .changed, now: now); res.changed += 1
                events.add(.changed, "\(i.displayName) changed after upload; uploading it again", ruleId: rule.id, fileId: v.id)
            }
            var row = FileRecord(ruleId: rule.id, path: i.path, displayName: i.displayName, mimeType: i.mimeType, kind: i.kind, sizeBytes: i.sizeBytes, modifiedAt: i.modifiedAt, takenAt: t)
            row.width = i.width; row.height = i.height; row.durationMs = i.durationMs; row.queuedAt = now; row.createdAt = now; row.updatedAt = now
            switch decision {
            case .go(let route, let sendAs, _, _): row.route = route; row.sendAs = sendAs
            case .skip(let why): row.state = .skipped; row.lastError = why; res.skippedByRouter += 1
            }
            pending.append(row)
            if pending.count >= 500 { res.newFiles += store.insertAll(pending); pending.removeAll() }
        }
        if !pending.isEmpty { res.newFiles += store.insertAll(pending) }

        for f in store.byRuleAndStates(rule.id, [.queued, .failed, .skipped, .verified]) where !seen.contains(f.path) && !source.exists(f.path) {
            _ = try? store.apply(f.id, .vanished, now: now); res.gone += 1
            events.add(.gone, "\(f.displayName) was removed from the phone", ruleId: rule.id, fileId: f.id)
        }
        events.add(.scanDone, "\(rule.name): \(res.newFiles) new file\(res.newFiles == 1 ? "" : "s")", ruleId: rule.id)
        settings.lastScanAt = now
        return res
    }
}

public enum Caption {
    public static let max = 1024
    public static func build(displayName: String, takenAt: Int64, ruleName: String, sha256: String?) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy HH:mm"
        let line2 = "\(f.string(from: Date(timeIntervalSince1970: Double(takenAt) / 1000))) · \(ruleName)"
        let line3 = sha256.map { "#tb \($0.prefix(12))" } ?? ""
        let extras = (line3.isEmpty ? 0 : line3.count + 1) + line2.count + 1
        let name = shorten(displayName, Swift.max(10, max - extras))
        return String([name, line2, line3].filter { !$0.isEmpty }.joined(separator: "\n").prefix(max))
    }
    public static func shorten(_ t: String, _ m: Int) -> String {
        if t.count <= m { return t }
        let keep = m - 3; return String(t.prefix((keep + 1) / 2)) + "..." + String(t.suffix(keep / 2))
    }
}
