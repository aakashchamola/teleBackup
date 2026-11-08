import Foundation

public struct StateCount { public var ruleId: Int64; public var state: FileState; public var count: Int; public var bytes: Int64 }
public struct QueueCount { public var count: Int; public var bytes: Int64 }

/// All tables behind one object. The state of a file row changes only through `apply`, which runs the state machine.
public final class Store {
    public let db: Db

    public init(path: String) throws {
        db = try Db(path: path)
        try migrate()
    }
    public static func inMemory() throws -> Store { try Store(path: ":memory:") }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS rules(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, folderPath TEXT, includeSubfolders INT, mediaTypes TEXT,
          topicId INT, uploadAs TEXT, mode TEXT, retentionDays INT, startMode TEXT, startDate INT, enabled INT, dryRun INT,
          deleteWarningAcceptedAt INT, deletedAt INT, createdAt INT, updatedAt INT, sortDocuments INT);
        CREATE TABLE IF NOT EXISTS topics(threadId INTEGER PRIMARY KEY, chatId INT, name TEXT, madeByApp INT, missing INT, createdAt INT);
        CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY AUTOINCREMENT, ruleId INT, path TEXT, displayName TEXT, mimeType TEXT, kind TEXT,
          sizeBytes INT, modifiedAt INT, takenAt INT, width INT, height INT, durationMs INT, sha256 TEXT, state TEXT, route TEXT, sendAs TEXT,
          attempts INT, nextAttemptAt INT, lastError TEXT, tgChatId INT, tgThreadId INT, tgMessageId INT, tgFileUniqueId TEXT, tgSize INT,
          tgWidth INT, tgHeight INT, tgDurationMs INT, queuedAt INT, uploadedAt INT, verifiedAt INT, deleteAfter INT, deletedAt INT,
          freedBytes INT, reviewId INT, createdAt INT, updatedAt INT, topicId INT, partCount INT,
          UNIQUE(ruleId, path, sizeBytes, modifiedAt));
        CREATE INDEX IF NOT EXISTS f_state ON files(state, nextAttemptAt);
        CREATE INDEX IF NOT EXISTS f_rule ON files(ruleId, state);
        CREATE TABLE IF NOT EXISTS reviews(id INTEGER PRIMARY KEY AUTOINCREMENT, ruleId INT, createdAt INT, fileCount INT, totalBytes INT, status TEXT, decidedAt INT);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, at INT, kind TEXT, ruleId INT, fileId INT, bytes INT, message TEXT);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS restored(key TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS bgjobs(fileId INTEGER PRIMARY KEY, hash TEXT, json TEXT, bodyPath TEXT, bytes INT, createdAt INT);
        """)
    }

    // MARK: rules
    private let ruleCols = "id,name,folderPath,includeSubfolders,mediaTypes,topicId,uploadAs,mode,retentionDays,startMode,startDate,enabled,dryRun,deleteWarningAcceptedAt,deletedAt,createdAt,updatedAt,sortDocuments"
    private func rule(_ r: Row) -> Rule {
        var x = Rule(name: r.text(1), folderPath: r.text(2))
        x.id = r.int(0); x.includeSubfolders = r.bool(3); x.mediaTypes = MediaTypes(rawValue: r.text(4)) ?? .both
        x.topicId = r.optInt(5); x.uploadAs = UploadAs(rawValue: r.text(6)) ?? .media; x.mode = RuleMode(rawValue: r.text(7)) ?? .uploadOnly
        x.retentionDays = Int(r.int(8)); x.startMode = StartMode(rawValue: r.text(9)) ?? .today; x.startDate = r.optInt(10)
        x.enabled = r.bool(11); x.dryRun = r.bool(12); x.deleteWarningAcceptedAt = r.optInt(13); x.deletedAt = r.optInt(14)
        x.createdAt = r.int(15); x.updatedAt = r.int(16); x.sortDocuments = r.bool(17)
        return x
    }
    private func ruleArgs(_ x: Rule) -> [DbValue] {
        [x.name.v, x.folderPath.v, x.includeSubfolders.v, x.mediaTypes.rawValue.v, x.topicId.v, x.uploadAs.rawValue.v, x.mode.rawValue.v,
         x.retentionDays.v, x.startMode.rawValue.v, x.startDate.v, x.enabled.v, x.dryRun.v, x.deleteWarningAcceptedAt.v, x.deletedAt.v,
         x.createdAt.v, x.updatedAt.v, x.sortDocuments.v]
    }
    public func rule(id: Int64) -> Rule? { try? db.query("SELECT \(ruleCols) FROM rules WHERE id=?", [id.v], rule).first }
    public func activeRules() -> [Rule] { (try? db.query("SELECT \(ruleCols) FROM rules WHERE deletedAt IS NULL ORDER BY id", [], rule)) ?? [] }
    public func allRules() -> [Rule] { (try? db.query("SELECT \(ruleCols) FROM rules ORDER BY id", [], rule)) ?? [] }
    @discardableResult public func insert(rule x: Rule) -> Int64 {
        (try? db.insert("INSERT INTO rules(name,folderPath,includeSubfolders,mediaTypes,topicId,uploadAs,mode,retentionDays,startMode,startDate,enabled,dryRun,deleteWarningAcceptedAt,deletedAt,createdAt,updatedAt,sortDocuments) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ruleArgs(x))) ?? 0
    }
    public func update(rule x: Rule) {
        _ = try? db.exec("UPDATE rules SET name=?,folderPath=?,includeSubfolders=?,mediaTypes=?,topicId=?,uploadAs=?,mode=?,retentionDays=?,startMode=?,startDate=?,enabled=?,dryRun=?,deleteWarningAcceptedAt=?,deletedAt=?,createdAt=?,updatedAt=?,sortDocuments=? WHERE id=?", ruleArgs(x) + [x.id.v])
    }

    // MARK: topics
    private func topic(_ r: Row) -> TopicRecord {
        var t = TopicRecord(threadId: r.int(0), chatId: r.int(1), name: r.text(2)); t.madeByApp = r.bool(3); t.missing = r.bool(4); t.createdAt = r.int(5); return t
    }
    public func topic(threadId: Int64) -> TopicRecord? { try? db.query("SELECT threadId,chatId,name,madeByApp,missing,createdAt FROM topics WHERE threadId=?", [threadId.v], topic).first }
    public func topics(chatId: Int64) -> [TopicRecord] { (try? db.query("SELECT threadId,chatId,name,madeByApp,missing,createdAt FROM topics WHERE chatId=? ORDER BY createdAt", [chatId.v], topic)) ?? [] }
    public func upsert(topic t: TopicRecord) {
        _ = try? db.exec("INSERT OR REPLACE INTO topics(threadId,chatId,name,madeByApp,missing,createdAt) VALUES(?,?,?,?,?,?)", [t.threadId.v, t.chatId.v, t.name.v, t.madeByApp.v, t.missing.v, t.createdAt.v])
    }
    public func markMissing(threadId: Int64, _ missing: Bool) { _ = try? db.exec("UPDATE topics SET missing=? WHERE threadId=?", [missing.v, threadId.v]) }

    // MARK: files
    private let fileCols = "id,ruleId,path,displayName,mimeType,kind,sizeBytes,modifiedAt,takenAt,width,height,durationMs,sha256,state,route,sendAs,attempts,nextAttemptAt,lastError,tgChatId,tgThreadId,tgMessageId,tgFileUniqueId,tgSize,tgWidth,tgHeight,tgDurationMs,queuedAt,uploadedAt,verifiedAt,deleteAfter,deletedAt,freedBytes,reviewId,createdAt,updatedAt,topicId,partCount"
    private func file(_ r: Row) -> FileRecord {
        var f = FileRecord(ruleId: r.int(1), path: r.text(2), displayName: r.text(3), mimeType: r.text(4), kind: FileKind(rawValue: r.text(5)) ?? .photo,
                           sizeBytes: r.int(6), modifiedAt: r.int(7), takenAt: r.int(8))
        f.id = r.int(0); f.width = r.optInt(9).map(Int.init); f.height = r.optInt(10).map(Int.init); f.durationMs = r.optInt(11); f.sha256 = r.optText(12)
        f.state = FileState(rawValue: r.text(13)) ?? .queued; f.route = r.optText(14).flatMap(Route.init); f.sendAs = r.optText(15).flatMap(SendAs.init)
        f.attempts = Int(r.int(16)); f.nextAttemptAt = r.optInt(17); f.lastError = r.optText(18); f.tgChatId = r.optInt(19); f.tgThreadId = r.optInt(20)
        f.tgMessageId = r.optInt(21); f.tgFileUniqueId = r.optText(22); f.tgSize = r.optInt(23); f.tgWidth = r.optInt(24).map(Int.init); f.tgHeight = r.optInt(25).map(Int.init)
        f.tgDurationMs = r.optInt(26); f.queuedAt = r.int(27); f.uploadedAt = r.optInt(28); f.verifiedAt = r.optInt(29); f.deleteAfter = r.optInt(30)
        f.deletedAt = r.optInt(31); f.freedBytes = r.int(32); f.reviewId = r.optInt(33); f.createdAt = r.int(34); f.updatedAt = r.int(35)
        f.topicId = r.optInt(36); f.partCount = Int(r.int(37))
        return f
    }
    private func fileArgs(_ f: FileRecord) -> [DbValue] {
        [f.ruleId.v, f.path.v, f.displayName.v, f.mimeType.v, f.kind.rawValue.v, f.sizeBytes.v, f.modifiedAt.v, f.takenAt.v, f.width.v, f.height.v, f.durationMs.v,
         f.sha256.v, f.state.rawValue.v, f.route?.rawValue.v ?? .null, f.sendAs?.rawValue.v ?? .null, f.attempts.v, f.nextAttemptAt.v, f.lastError.v,
         f.tgChatId.v, f.tgThreadId.v, f.tgMessageId.v, f.tgFileUniqueId.v, f.tgSize.v, f.tgWidth.v, f.tgHeight.v, f.tgDurationMs.v, f.queuedAt.v,
         f.uploadedAt.v, f.verifiedAt.v, f.deleteAfter.v, f.deletedAt.v, f.freedBytes.v, f.reviewId.v, f.createdAt.v, f.updatedAt.v, f.topicId.v, f.partCount.v]
    }
    private func files(_ sql: String, _ args: [DbValue] = []) -> [FileRecord] { (try? db.query("SELECT \(fileCols) FROM files " + sql, args, file)) ?? [] }

    public func file(id: Int64) -> FileRecord? { files("WHERE id=?", [id.v]).first }
    public func find(ruleId: Int64, path: String, size: Int64, modifiedAt: Int64) -> FileRecord? {
        files("WHERE ruleId=? AND path=? AND sizeBytes=? AND modifiedAt=? LIMIT 1", [ruleId.v, path.v, size.v, modifiedAt.v]).first
    }
    public func findByPath(ruleId: Int64, path: String) -> [FileRecord] { files("WHERE ruleId=? AND path=?", [ruleId.v, path.v]) }

    /// Inserts new rows; rows that collide with an existing identity are skipped. Returns how many went in.
    @discardableResult public func insertAll(_ list: [FileRecord]) -> Int {
        var n = 0
        _ = try? db.transaction {
            for f in list {
                n += (try? db.exec("INSERT OR IGNORE INTO files(ruleId,path,displayName,mimeType,kind,sizeBytes,modifiedAt,takenAt,width,height,durationMs,sha256,state,route,sendAs,attempts,nextAttemptAt,lastError,tgChatId,tgThreadId,tgMessageId,tgFileUniqueId,tgSize,tgWidth,tgHeight,tgDurationMs,queuedAt,uploadedAt,verifiedAt,deleteAfter,deletedAt,freedBytes,reviewId,createdAt,updatedAt,topicId,partCount) VALUES(\(Array(repeating: "?", count: 37).joined(separator: ",")))", fileArgs(f))) ?? 0
            }
        }
        return n
    }
    /// Changes anything but the state.
    public func updateDetails(_ f: FileRecord) {
        guard let cur = file(id: f.id) else { return }
        var n = f; n.state = cur.state
        _ = try? db.exec("UPDATE files SET ruleId=?,path=?,displayName=?,mimeType=?,kind=?,sizeBytes=?,modifiedAt=?,takenAt=?,width=?,height=?,durationMs=?,sha256=?,state=?,route=?,sendAs=?,attempts=?,nextAttemptAt=?,lastError=?,tgChatId=?,tgThreadId=?,tgMessageId=?,tgFileUniqueId=?,tgSize=?,tgWidth=?,tgHeight=?,tgDurationMs=?,queuedAt=?,uploadedAt=?,verifiedAt=?,deleteAfter=?,deletedAt=?,freedBytes=?,reviewId=?,createdAt=?,updatedAt=?,topicId=?,partCount=? WHERE id=?", fileArgs(n) + [f.id.v])
    }
    /// The only door for state changes.
    @discardableResult
    public func apply(_ id: Int64, _ event: FileEvent, now: Int64, maxAttempts: Int = FileStateMachine.defaultMaxAttempts, jitter: Double = 0) throws -> FileRecord {
        guard let cur = file(id: id) else { throw NSError(domain: "Store", code: 404) }
        let next = try FileStateMachine.transition(cur, event, now: now, maxAttempts: maxAttempts, jitter01: jitter)
        _ = try db.exec("UPDATE files SET ruleId=?,path=?,displayName=?,mimeType=?,kind=?,sizeBytes=?,modifiedAt=?,takenAt=?,width=?,height=?,durationMs=?,sha256=?,state=?,route=?,sendAs=?,attempts=?,nextAttemptAt=?,lastError=?,tgChatId=?,tgThreadId=?,tgMessageId=?,tgFileUniqueId=?,tgSize=?,tgWidth=?,tgHeight=?,tgDurationMs=?,queuedAt=?,uploadedAt=?,verifiedAt=?,deleteAfter=?,deletedAt=?,freedBytes=?,reviewId=?,createdAt=?,updatedAt=?,topicId=?,partCount=? WHERE id=?", fileArgs(next) + [id.v])
        return next
    }

    private let queueWhere = """
      FROM files f INNER JOIN rules r ON r.id=f.ruleId WHERE r.enabled=1 AND r.deletedAt IS NULL
      AND ((f.state='queued' AND (f.nextAttemptAt IS NULL OR f.nextAttemptAt<=?1)) OR (f.state='failed' AND f.nextAttemptAt<=?1))
      AND ((f.route='account' AND ?3=1) OR ((f.route='bot' OR f.route IS NULL) AND ?2=1))
      """
    /// Next file to upload, oldest first.
    public func nextInQueue(now: Int64, allowBot: Bool, allowAccount: Bool, excludeRuleIds: Set<Int64> = []) -> FileRecord? {
        let ex = excludeRuleIds.isEmpty ? "" : " AND f.ruleId NOT IN (\(excludeRuleIds.map(String.init).joined(separator: ",")))"
        let cols = fileCols.split(separator: ",").map { "f." + $0 }.joined(separator: ",")
        return (try? db.query("SELECT \(cols) \(queueWhere)\(ex) ORDER BY f.takenAt ASC, f.id ASC LIMIT 1", [now.v, allowBot.v, allowAccount.v], file))?.first
    }
    public func queueCount(now: Int64, allowBot: Bool, allowAccount: Bool) -> QueueCount {
        (try? db.query("SELECT COUNT(*), COALESCE(SUM(f.sizeBytes),0) \(queueWhere)", [now.v, allowBot.v, allowAccount.v]) { QueueCount(count: Int($0.int(0)), bytes: $0.int(1)) })?.first ?? QueueCount(count: 0, bytes: 0)
    }
    public func waitingAccountCount() -> Int { Int((try? db.query("SELECT COUNT(*) FROM files WHERE state='queued' AND route='account'", []) { $0.int(0) })?.first ?? 0) }
    public func earliestRetryAt() -> Int64? { (try? db.query("SELECT MIN(nextAttemptAt) FROM files WHERE state IN ('queued','failed') AND nextAttemptAt IS NOT NULL", []) { $0.optInt(0) })?.first ?? nil }
    public func interrupted() -> [FileRecord] { files("WHERE state='uploading'") }
    public func byRuleAndStates(_ ruleId: Int64, _ states: [FileState]) -> [FileRecord] {
        files("WHERE ruleId=? AND state IN (\(states.map { "'\($0.rawValue)'" }.joined(separator: ",")))", [ruleId.v])
    }
    public func verifiedDue(ruleId: Int64, now: Int64, limit: Int) -> [FileRecord] {
        files("WHERE ruleId=? AND state='verified' AND partCount=1 AND deleteAfter IS NOT NULL AND deleteAfter<=? ORDER BY takenAt ASC LIMIT ?", [ruleId.v, now.v, limit.v])
    }
    public func inReview(_ reviewId: Int64) -> [FileRecord] { files("WHERE reviewId=?", [reviewId.v]) }
    public func setReview(_ ids: [Int64], _ reviewId: Int64?) {
        guard !ids.isEmpty else { return }
        _ = try? db.exec("UPDATE files SET reviewId=? WHERE id IN (\(ids.map(String.init).joined(separator: ",")))", [reviewId.v])
    }
    public func stateCounts() -> [StateCount] {
        (try? db.query("SELECT ruleId,state,COUNT(*),COALESCE(SUM(sizeBytes),0) FROM files GROUP BY ruleId,state", []) {
            StateCount(ruleId: $0.int(0), state: FileState(rawValue: $0.text(1)) ?? .queued, count: Int($0.int(2)), bytes: $0.int(3))
        }) ?? []
    }
    private func scalar(_ sql: String, _ a: [DbValue] = []) -> Int64 { (try? db.query(sql, a) { $0.int(0) })?.first ?? 0 }
    public func freedBytesSince(_ t: Int64) -> Int64 { scalar("SELECT COALESCE(SUM(freedBytes),0) FROM files WHERE state='deleted' AND deletedAt>=?", [t.v]) }
    public func freedBytesTotal() -> Int64 { scalar("SELECT COALESCE(SUM(freedBytes),0) FROM files WHERE state='deleted'") }
    public func uploadedCountSince(_ t: Int64) -> Int { Int(scalar("SELECT COUNT(*) FROM files WHERE uploadedAt>=?", [t.v])) }
    public func skippedCountSince(_ t: Int64) -> Int { Int(scalar("SELECT COUNT(*) FROM files WHERE state='skipped' AND updatedAt>=?", [t.v])) }
    public func page(ruleId: Int64?, state: FileState?, cursor: Int64?, limit: Int) -> [FileRecord] {
        files("WHERE (?1 IS NULL OR ruleId=?1) AND (?2 IS NULL OR state=?2) AND (?3 IS NULL OR id<?3) ORDER BY id DESC LIMIT ?4", [ruleId.v, state?.rawValue.v ?? .null, cursor.v, limit.v])
    }
    public func verified(ruleId: Int64) -> [FileRecord] { files("WHERE ruleId=? AND state='verified'", [ruleId.v]) }
    public func setDeleteAfter(_ id: Int64, _ t: Int64?) { _ = try? db.exec("UPDATE files SET deleteAfter=? WHERE id=?", [t.v, id.v]) }

    // MARK: reviews
    private func review(_ r: Row) -> ReviewRecord {
        var x = ReviewRecord(ruleId: r.int(1), createdAt: r.int(2), fileCount: Int(r.int(3)), totalBytes: r.int(4))
        x.id = r.int(0); x.status = ReviewStatus(rawValue: r.text(5)) ?? .waiting; x.decidedAt = r.optInt(6); return x
    }
    public func review(id: Int64) -> ReviewRecord? { try? db.query("SELECT id,ruleId,createdAt,fileCount,totalBytes,status,decidedAt FROM reviews WHERE id=?", [id.v], review).first }
    public func waitingReview(ruleId: Int64) -> ReviewRecord? { try? db.query("SELECT id,ruleId,createdAt,fileCount,totalBytes,status,decidedAt FROM reviews WHERE ruleId=? AND status='waiting' LIMIT 1", [ruleId.v], review).first }
    public func allWaitingReviews() -> [ReviewRecord] { (try? db.query("SELECT id,ruleId,createdAt,fileCount,totalBytes,status,decidedAt FROM reviews WHERE status='waiting'", [], review)) ?? [] }
    @discardableResult public func insert(review x: ReviewRecord) -> Int64 {
        (try? db.insert("INSERT INTO reviews(ruleId,createdAt,fileCount,totalBytes,status,decidedAt) VALUES(?,?,?,?,?,?)", [x.ruleId.v, x.createdAt.v, x.fileCount.v, x.totalBytes.v, x.status.rawValue.v, x.decidedAt.v])) ?? 0
    }
    public func update(review x: ReviewRecord) {
        _ = try? db.exec("UPDATE reviews SET fileCount=?,totalBytes=?,status=?,decidedAt=? WHERE id=?", [x.fileCount.v, x.totalBytes.v, x.status.rawValue.v, x.decidedAt.v, x.id.v])
    }

    // MARK: events
    private func event(_ r: Row) -> EventRecord {
        var e = EventRecord(at: r.int(1), kind: EventKind(rawValue: r.text(2)) ?? .scanDone, message: r.text(6), ruleId: r.optInt(3), fileId: r.optInt(4), bytes: r.optInt(5)); e.id = r.int(0); return e
    }
    public func insert(event e: EventRecord) {
        _ = try? db.exec("INSERT INTO events(at,kind,ruleId,fileId,bytes,message) VALUES(?,?,?,?,?,?)", [e.at.v, e.kind.rawValue.v, e.ruleId.v, e.fileId.v, e.bytes.v, e.message.v])
    }
    public func events(kinds: Set<EventKind>?, ruleId: Int64?, search: String?, beforeId: Int64?, limit: Int) -> [EventRecord] {
        let k = kinds.map { "AND kind IN (\($0.map { "'\($0.rawValue)'" }.joined(separator: ",")))" } ?? ""
        return (try? db.query("SELECT id,at,kind,ruleId,fileId,bytes,message FROM events WHERE (?1 IS NULL OR ruleId=?1) AND (?2 IS NULL OR message LIKE '%'||?2||'%') AND (?3 IS NULL OR id<?3) \(k) ORDER BY id DESC LIMIT ?4",
                              [ruleId.v, search.v, beforeId.v, limit.v], event)) ?? []
    }
    public func prune(before: Int64) -> Int { (try? db.exec("DELETE FROM events WHERE at<?", [before.v])) ?? 0 }

    // MARK: uploads handed to the system (iOS keeps sending them with the screen off)
    public func putBgJob(_ j: BgJobRecord) {
        _ = try? db.exec("INSERT OR REPLACE INTO bgjobs(fileId,hash,json,bodyPath,bytes,createdAt) VALUES(?,?,?,?,?,?)", [j.fileId.v, j.hash.v, j.json.v, j.bodyPath.v, j.bytes.v, j.createdAt.v])
    }
    private func bgJob(_ r: Row) -> BgJobRecord { BgJobRecord(fileId: r.int(0), hash: r.text(1), json: r.text(2), bodyPath: r.text(3), bytes: r.int(4), createdAt: r.int(5)) }
    public func bgJob(_ fileId: Int64) -> BgJobRecord? { try? db.query("SELECT fileId,hash,json,bodyPath,bytes,createdAt FROM bgjobs WHERE fileId=?", [fileId.v], bgJob).first }
    public func bgJobs() -> [BgJobRecord] { (try? db.query("SELECT fileId,hash,json,bodyPath,bytes,createdAt FROM bgjobs", [], bgJob)) ?? [] }
    public func removeBgJob(_ fileId: Int64) { _ = try? db.exec("DELETE FROM bgjobs WHERE fileId=?", [fileId.v]) }
    public func bgOutstanding() -> (count: Int, bytes: Int64) {
        let r = (try? db.query("SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM bgjobs", []) { ($0.int(0), $0.int(1)) })?.first ?? (0, 0)
        return (Int(r.0), r.1)
    }

    // MARK: restored (files found in Telegram after a fresh install)
    public func addRestored(_ keys: [String]) {
        _ = try? db.transaction { for k in keys { _ = try? db.exec("INSERT OR IGNORE INTO restored(key) VALUES(?)", [k.v]) } }
    }
    public func isRestored(_ key: String) -> Bool { ((try? db.query("SELECT 1 FROM restored WHERE key=?", [key.v]) { $0.int(0) })?.first) != nil }
    public func restoredCount() -> Int { Int((try? db.query("SELECT COUNT(*) FROM restored", []) { $0.int(0) })?.first ?? 0) }

    // MARK: settings (key/value)
    public func setting(_ key: String) -> String? { (try? db.query("SELECT value FROM settings WHERE key=?", [key.v]) { $0.text(0) })?.first }
    public func put(_ key: String, _ value: String?) {
        if let v = value { _ = try? db.exec("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", [key.v, v.v]) }
        else { _ = try? db.exec("DELETE FROM settings WHERE key=?", [key.v]) }
    }
    public func clearAll() { _ = try? db.exec("DELETE FROM files; DELETE FROM rules; DELETE FROM topics; DELETE FROM reviews; DELETE FROM events; DELETE FROM settings; DELETE FROM restored; DELETE FROM bgjobs;") }
}
