package com.aakashchamola.telebackup.core.rules

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.FileStore
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.db.RuleStore
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.time.Time

object Retention {
    /** When a verified file may be deleted: [retentionDays] after verification (minutes in the debug time warp). */
    fun deleteAfter(verifiedAt: Long, retentionDays: Int, timeWarp: Boolean): Long =
        verifiedAt + retentionDays * (if (timeWarp) Time.MINUTE else Time.DAY)
}

class RuleException(val problems: List<RuleProblem>) : Exception(problems.joinToString("; ") { it.message })

/** Creating, changing, switching off and soft-deleting rules (docs/HOW_IT_WORKS.md section 3). */
class RuleRepository(
    private val rules: RuleStore,
    private val files: FileStore,
    private val settings: SettingsRepository,
    private val events: EventLog,
    private val clock: Clock,
) {
    fun active(): List<RuleEntity> = rules.active()
    fun get(id: Long): RuleEntity? = rules.get(id)

    /** Validates and saves. Returns the saved rule. Throws [RuleException] with plain-word problems. */
    fun save(input: RuleEntity, folderExists: Boolean = true): RuleEntity {
        val now = clock.now()
        val old = if (input.id != 0L) rules.get(input.id) else null
        val normalized = input.copy(name = input.name.trim(), folderPath = RuleValidator.normalizeFolder(input.folderPath))
        val others = rules.active().filter { it.id != input.id }.map { it.name }
        val problems = RuleValidator.validate(normalized, others, folderExists)
        if (problems.isNotEmpty()) throw RuleException(problems)

        val startDate = when (normalized.startMode) {
            StartMode.TODAY -> if (old != null && old.startMode == StartMode.TODAY) old.startDate else now
            StartMode.SINCE_DATE -> normalized.startDate
            StartMode.EVERYTHING -> null
        }
        val toSave = normalized.copy(startDate = startDate, updatedAt = now, createdAt = old?.createdAt ?: now)
        val id: Long
        if (old == null) {
            id = rules.insert(toSave)
        } else {
            id = old.id
            rules.update(toSave.copy(id = id, deletedAt = old.deletedAt))
        }
        val saved = rules.get(id)!!

        if (old != null) {
            if (old.retentionDays != saved.retentionDays || old.mode != saved.mode) refreshDeleteAfter(saved)
            val movedLater = (saved.startDate ?: Long.MIN_VALUE) > (old.startDate ?: Long.MIN_VALUE)
            if (movedLater) ignoreBeforeStart(saved, now)
        }
        return saved
    }

    fun setEnabled(id: Long, enabled: Boolean) {
        val r = rules.get(id) ?: return
        rules.update(r.copy(enabled = enabled, updatedAt = clock.now()))
    }

    /** Soft delete: the row stays so History can still name the rule. Its waiting files are dropped. */
    fun softDelete(id: Long) {
        val r = rules.get(id) ?: return
        val now = clock.now()
        rules.update(r.copy(deletedAt = now, enabled = false, updatedAt = now))
        for (f in files.byRuleAndStates(id, setOf(FileState.QUEUED, FileState.FAILED, FileState.SKIPPED))) {
            files.apply(f.id, FileEvent.Ignore, now)
        }
    }

    fun refreshDeleteAfter(rule: RuleEntity) {
        files.setDeleteAfterForRule(rule.id) { f ->
            if (rule.mode == RuleMode.UPLOAD_AND_DELETE && f.verifiedAt != null)
                Retention.deleteAfter(f.verifiedAt, rule.retentionDays, settings.timeWarp)
            else null
        }
    }

    private fun ignoreBeforeStart(rule: RuleEntity, now: Long) {
        val start = rule.startDate ?: return
        for (f in files.byRuleAndStates(rule.id, setOf(FileState.QUEUED, FileState.FAILED, FileState.SKIPPED))) {
            if (f.takenAt < start) files.apply(f.id, FileEvent.Ignore, now)
        }
    }

    fun exportable(): List<RuleEntity> = rules.active()
}

/** Stop all deletes now (docs/HOW_IT_WORKS.md section 12). */
class KillSwitch(
    private val rules: RuleStore,
    private val files: FileStore,
    private val reviews: com.aakashchamola.telebackup.core.db.ReviewStore,
    private val events: EventLog,
    private val clock: Clock,
) {
    fun stopAllDeletes() {
        val now = clock.now()
        for (r in rules.active()) {
            rules.update(r.copy(mode = RuleMode.UPLOAD_ONLY, dryRun = true, deleteWarningAcceptedAt = null, updatedAt = now))
            files.setDeleteAfterForRule(r.id) { null }
        }
        for (rv in reviews.allWaiting()) {
            reviews.update(rv.copy(status = ReviewStatus.DISMISSED, decidedAt = now))
            files.setReview(files.inReview(rv.id).map(FileEntity::id), null)
        }
        events.add(EventKind.KILL_SWITCH, "Stopped all deletes. Every rule is upload only.")
    }
}
