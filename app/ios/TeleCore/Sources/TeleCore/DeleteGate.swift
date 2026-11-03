import Foundation

/// What Photos says about the asset just now.
public struct DiskFacts: Equatable {
    public var exists: Bool
    public var sizeBytes: Int64
    public var modifiedAt: Int64
    public init(exists: Bool, sizeBytes: Int64, modifiedAt: Int64) { self.exists = exists; self.sizeBytes = sizeBytes; self.modifiedAt = modifiedAt }
}

public enum AccountCheck { case notReady, ok, mismatch, notFound, unavailable }

public enum GateResult {
    case allowed(DeletePermit)
    case denied(DenyReason)
}

/// The one decision "may this file be deleted from the phone now?". Pure: no I/O.
/// Allowed only if all nine conditions hold (docs/DATA_MODEL.md "The delete gate").
public enum DeleteGate {
    public static func check(file: FileRecord, rule: Rule, deletesBlockedReason: String?, disk: DiskFacts, now: Int64,
                             inApprovedReview: Bool, account: AccountCheck, allowBotOnly: Bool) -> GateResult {
        if file.state != .verified || file.tgMessageId == nil || file.tgChatId == nil { return .denied(.notVerified) }
        if file.partCount > 1 { return .denied(.sentInParts) }
        if rule.mode != .uploadAndDelete { return .denied(.ruleUploadOnly) }
        if rule.deleteWarningAcceptedAt == nil { return .denied(.noWarningAccepted) }
        if !rule.enabled || rule.deletedAt != nil { return .denied(.ruleOff) }
        if deletesBlockedReason != nil { return .denied(.deletesBlocked) }
        guard let due = file.deleteAfter, now >= due else { return .denied(.notDue) }
        if rule.dryRun && !inApprovedReview { return .denied(.needsReview) }
        if !disk.exists { return .denied(.fileMissing) }
        if disk.sizeBytes != file.sizeBytes || disk.modifiedAt != file.modifiedAt { return .denied(.fileChanged) }
        switch account {
        case .ok: break
        case .mismatch, .notFound: return .denied(.telegramMismatch)
        case .unavailable: return .denied(.noStrongCheck)
        case .notReady:
            if file.route == .account || !allowBotOnly { return .denied(.noStrongCheck) }
        }
        return .allowed(DeletePermit(fileId: file.id))
    }
}
