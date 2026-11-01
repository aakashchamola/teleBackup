package com.aakashchamola.telebackup.core.model

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.RuleEntity

/** What the cleaner saw on the disk just now. */
data class DiskFacts(val exists: Boolean, val sizeBytes: Long, val modifiedAt: Long)

/** Result of asking the account to re-fetch the Telegram message just before a delete. */
enum class AccountCheck {
    /** Account not logged in, so no strong check is possible. */
    NOT_READY,
    OK,
    MISMATCH,
    NOT_FOUND,
    /** Account logged in but could not be asked (offline, error). */
    UNAVAILABLE,
}

sealed class GateResult {
    /**
     * A permit to delete one file. Only [DeleteGate] can make one (internal constructor),
     * and [FileEvent.DeletedByCleaner] needs one, so DELETED cannot be reached any other way.
     */
    class Allowed internal constructor(val fileId: Long) : GateResult()

    data class Denied(val reason: DenyReason) : GateResult()
}

/**
 * The one decision "may this file be deleted from the phone now?". Pure: no I/O,
 * the caller passes in what it saw. Allowed only if all nine conditions hold
 * (docs/DATA_MODEL.md "The delete gate").
 */
object DeleteGate {
    fun check(
        file: FileEntity,
        rule: RuleEntity,
        deletesBlockedReason: String?,
        disk: DiskFacts,
        now: Long,
        inApprovedReview: Boolean,
        account: AccountCheck,
        allowBotOnly: Boolean,
    ): GateResult {
        // 1. verified, with the Telegram message saved
        if (file.state != FileState.VERIFIED || file.tgMessageId == null || file.tgChatId == null) {
            return deny(DenyReason.NOT_VERIFIED)
        }
        // 2. the rule deletes, and the person accepted the warning
        if (rule.mode != RuleMode.UPLOAD_AND_DELETE) return deny(DenyReason.RULE_UPLOAD_ONLY)
        if (rule.deleteWarningAcceptedAt == null) return deny(DenyReason.NO_WARNING_ACCEPTED)
        // 3. rule is on
        if (!rule.enabled || rule.deletedAt != null) return deny(DenyReason.RULE_OFF)
        // 4. deletes are not blocked for everyone
        if (deletesBlockedReason != null) return deny(DenyReason.DELETES_BLOCKED)
        // 5. retention has passed
        val due = file.deleteAfter
        if (due == null || now < due) return deny(DenyReason.NOT_DUE)
        // 6. first-run review approved (or the rule is past its dry run)
        if (rule.dryRun && !inApprovedReview) return deny(DenyReason.NEEDS_REVIEW)
        // 7. the file on disk is exactly the one that was uploaded
        if (!disk.exists) return deny(DenyReason.FILE_MISSING)
        if (disk.sizeBytes != file.sizeBytes || disk.modifiedAt != file.modifiedAt) {
            return deny(DenyReason.FILE_CHANGED)
        }
        // 8 + 9. strong check, or bot-only allowed by the owner's decision (D1)
        when (account) {
            AccountCheck.OK -> Unit
            AccountCheck.MISMATCH, AccountCheck.NOT_FOUND -> return deny(DenyReason.TELEGRAM_MISMATCH)
            AccountCheck.UNAVAILABLE -> return deny(DenyReason.NO_STRONG_CHECK)
            AccountCheck.NOT_READY -> {
                if (file.route == Route.ACCOUNT || !allowBotOnly) return deny(DenyReason.NO_STRONG_CHECK)
            }
        }
        return GateResult.Allowed(file.id)
    }

    private fun deny(r: DenyReason) = GateResult.Denied(r)
}
