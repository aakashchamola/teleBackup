package com.aakashchamola.telebackup.core.clean

import com.aakashchamola.telebackup.core.db.*
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.upload.DiskInspector

/** Asks the Telegram account to fetch the message again just before a delete (the strong check). */
interface AccountVerifier {
    suspend fun recheck(file: FileEntity): AccountCheck
}

interface ReviewNotifier {
    fun reviewWaiting(rule: RuleEntity, review: ReviewEntity)
}

data class CleanOutcome(
    val deleted: Int = 0,
    val freedBytes: Long = 0,
    val denied: Int = 0,
    val reviewsCreated: Int = 0,
    val blockedReason: String? = null,
)

/** Retention delete (docs/HOW_IT_WORKS.md section 10). Every delete goes through [DeleteGate] and [FileDeleter]. */
class Cleaner(
    private val rules: RuleStore,
    private val files: FileStore,
    private val reviews: ReviewStore,
    private val events: EventLog,
    private val settings: SettingsRepository,
    private val clock: Clock,
    private val disk: DiskInspector,
    private val deleter: FileDeleter,
    private val accountVerifier: AccountVerifier?,
    private val notifier: ReviewNotifier?,
) {
    companion object { const val PER_RULE_CAP = 500 }

    /**
     * @param allFilesAccess whether the phone still lets us touch the folders
     * @param onlyReviewId when set (a review was just approved) only that review's files are considered
     */
    suspend fun run(allFilesAccess: Boolean, onlyReviewId: Long? = null): CleanOutcome {
        updateBlock(allFilesAccess)
        val blocked = settings.deletesBlockedReason
        if (blocked != null) return CleanOutcome(blockedReason = blocked)

        var deleted = 0; var freed = 0L; var denied = 0; var created = 0
        for (rule in rules.active()) {
            if (rule.mode != RuleMode.UPLOAD_AND_DELETE || !rule.enabled) continue
            val now = clock.now()
            val candidates = if (onlyReviewId != null) files.inReview(onlyReviewId).filter { it.ruleId == rule.id && it.state == FileState.VERIFIED }
            else files.verifiedDue(rule.id, now, PER_RULE_CAP)
            if (candidates.isEmpty()) continue

            if (rule.dryRun && onlyReviewId == null) {
                if (ensureReview(rule, candidates, now)) created++
                continue
            }
            for (c in candidates) {
                when (val r = process(c, rule)) {
                    is Step.Deleted -> { deleted++; freed += r.bytes }
                    Step.Denied -> denied++
                }
            }
        }
        settings.lastCleanAt = clock.now()
        return CleanOutcome(deleted, freed, denied, created)
    }

    /** Lifts or sets the global block depending on the phone's all-files access. */
    fun updateBlock(allFilesAccess: Boolean) {
        val cur = settings.deletesBlockedReason
        if (!allFilesAccess && cur == null) {
            settings.deletesBlockedReason = "PERMISSION_LOST"
            events.add(EventKind.PERMISSION_LOST, "teleBackup lost access to all files")
        } else if (allFilesAccess && cur == "PERMISSION_LOST") {
            settings.deletesBlockedReason = null
            events.add(EventKind.PERMISSION_BACK, "teleBackup can reach your files again")
        }
    }

    private fun ensureReview(rule: RuleEntity, candidates: List<FileEntity>, now: Long): Boolean {
        val existing = reviews.waitingFor(rule.id)
        val total = candidates.sumOf { it.sizeBytes }
        if (existing != null) {
            reviews.update(existing.copy(fileCount = candidates.size, totalBytes = total))
            files.setReview(candidates.map { it.id }, existing.id)
            return false
        }
        val id = reviews.insert(ReviewEntity(ruleId = rule.id, createdAt = now, fileCount = candidates.size, totalBytes = total))
        files.setReview(candidates.map { it.id }, id)
        events.add(EventKind.REVIEW_CREATED, "${rule.name}: ${candidates.size} files are ready to delete. Check them first.", rule.id)
        notifier?.reviewWaiting(rule, reviews.get(id)!!)
        return true
    }

    private sealed class Step {
        data class Deleted(val bytes: Long) : Step()
        object Denied : Step()
    }

    private suspend fun process(file: FileEntity, rule: RuleEntity): Step {
        val now = clock.now()
        val facts = disk.inspect(file.path)
        val account = if (settings.accountState == AccountValue.READY && accountVerifier != null)
            accountVerifier.recheck(file) else AccountCheck.NOT_READY
        val approved = file.reviewId?.let { reviews.get(it)?.status == ReviewStatus.APPROVED } ?: false
        val result = DeleteGate.check(
            file, rule, settings.deletesBlockedReason, facts, now, approved, account, settings.allowBotOnlyDelete,
        )
        return when (result) {
            is GateResult.Allowed -> when (val out = deleter.removeFromPhone(file)) {
                is DeleteOutcome.Deleted -> {
                    files.apply(file.id, FileEvent.DeletedByCleaner(result, out.bytes), clock.now())
                    events.add(EventKind.DELETED, "${file.displayName} deleted from the phone", rule.id, file.id, out.bytes)
                    Step.Deleted(out.bytes)
                }
                is DeleteOutcome.Failed -> {
                    note(file, rule, "DELETE_FAILED", out.reason)
                    Step.Denied
                }
            }
            is GateResult.Denied -> {
                when (result.reason) {
                    DenyReason.FILE_CHANGED -> files.apply(file.id, FileEvent.Changed, now)
                    DenyReason.FILE_MISSING -> files.apply(file.id, FileEvent.Vanished, now)
                    DenyReason.TELEGRAM_MISMATCH -> files.apply(file.id, FileEvent.TelegramLost, now)
                    else -> Unit
                }
                note(file, rule, result.reason.name, null)
                Step.Denied
            }
        }
    }

    /** One DELETE_DENIED event per file per reason. */
    private fun note(file: FileEntity, rule: RuleEntity, reason: String, detail: String?) {
        val tag = "Delete waiting: $reason"
        val current = files.get(file.id) ?: return
        if (current.lastError == tag) return
        if (!current.state.terminal && current.state == file.state) files.updateDetails(current.copy(lastError = tag))
        events.add(EventKind.DELETE_DENIED, "${file.displayName} was not deleted ($reason${detail?.let { ": $it" } ?: ""})", rule.id, file.id)
    }
}

/** Approving or dismissing a first-delete review. */
class Reviews(
    private val rules: RuleStore,
    private val files: FileStore,
    private val reviews: ReviewStore,
    private val events: EventLog,
    private val clock: Clock,
) {
    /** Marks the review approved and turns the rule's dry run off. The caller then runs the cleaner for this review only. */
    fun approve(reviewId: Long) {
        val rv = reviews.get(reviewId) ?: return
        if (rv.status != ReviewStatus.WAITING) return
        val now = clock.now()
        reviews.update(rv.copy(status = ReviewStatus.APPROVED, decidedAt = now))
        rules.get(rv.ruleId)?.let { rules.update(it.copy(dryRun = false, updatedAt = now)) }
        events.add(EventKind.REVIEW_APPROVED, "Delete approved for ${rv.fileCount} files", rv.ruleId)
    }

    fun dismiss(reviewId: Long) {
        val rv = reviews.get(reviewId) ?: return
        reviews.update(rv.copy(status = ReviewStatus.DISMISSED, decidedAt = clock.now()))
        files.setReview(files.inReview(reviewId).map { it.id }, null)
    }
}
