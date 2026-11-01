package com.aakashchamola.telebackup.core.scan

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.FileStore
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.Retention
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.time.Time
import com.aakashchamola.telebackup.core.upload.Router
import com.aakashchamola.telebackup.core.upload.RouteDecision
import com.aakashchamola.telebackup.core.upload.RouterLimits
import java.time.ZoneId

/** One media file as the phone reports it. */
data class MediaItem(
    val mediaStoreId: Long?,
    val path: String,
    val displayName: String,
    val mimeType: String,
    val sizeBytes: Long,
    val modifiedAt: Long,
    val takenAt: Long?,
    val width: Int?,
    val height: Int?,
    val durationMs: Long?,
    val kind: FileKind,
)

/** Where files come from: MediaStore, the file system, or a fake in tests. */
interface MediaSource {
    /** Files in [folderPath] (relative to shared storage, trailing slash), filtered by type. */
    fun list(folderPath: String, includeSubfolders: Boolean, types: MediaTypes): List<MediaItem>
    fun exists(path: String): Boolean
    fun folderExists(folderPath: String): Boolean
}

data class ScanResult(
    val newFiles: Int = 0,
    val updated: Int = 0,
    val changed: Int = 0,
    val gone: Int = 0,
    val tooNew: Int = 0,
    val notIncluded: Int = 0,
    val skippedByRouter: Int = 0,
)

data class BacklogPreview(val count: Int, val bytes: Long, val newestAt: Long?, val oldestAt: Long?)

/** Finds files for a rule and queues them, newest first (docs/HOW_IT_WORKS.md section 4). */
class Scanner(
    private val source: MediaSource,
    private val files: FileStore,
    private val settings: SettingsRepository,
    private val events: EventLog,
    private val clock: Clock,
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    companion object {
        const val MIN_AGE_MS = 2 * Time.MINUTE
        const val BATCH = 500
    }

    private fun limits() = RouterLimits(botMaxBytes = settings.botMaxBytes, botPhotoMaxBytes = settings.botPhotoMaxBytes)

    private fun takenAt(i: MediaItem): Long = i.takenAt ?: TakenAt.fromName(i.displayName, zone) ?: i.modifiedAt

    private fun included(rule: RuleEntity, taken: Long): Boolean {
        val start = rule.startDate
        return rule.startMode == StartMode.EVERYTHING || start == null || taken >= start
    }

    /** Counts what a rule would queue, without touching the database. */
    fun preview(rule: RuleEntity): BacklogPreview {
        val now = clock.now()
        var count = 0; var bytes = 0L; var newest: Long? = null; var oldest: Long? = null
        for (i in source.list(rule.folderPath, rule.includeSubfolders, rule.mediaTypes)) {
            if (i.modifiedAt > now - MIN_AGE_MS) continue
            val t = takenAt(i)
            if (!included(rule, t)) continue
            count++; bytes += i.sizeBytes
            newest = maxOf(newest ?: t, t); oldest = minOf(oldest ?: t, t)
        }
        return BacklogPreview(count, bytes, newest, oldest)
    }

    fun scan(rule: RuleEntity): ScanResult {
        if (!rule.enabled || rule.deletedAt != null) return ScanResult()
        val now = clock.now()
        var newFiles = 0; var updated = 0; var changed = 0; var gone = 0; var tooNew = 0; var notIncluded = 0; var routed = 0
        val seen = HashSet<String>()
        val pending = ArrayList<FileEntity>()

        // newest first, so a big backlog starts with recent files
        val items = source.list(rule.folderPath, rule.includeSubfolders, rule.mediaTypes)
            .sortedByDescending { takenAt(it) }

        for (i in items) {
            seen += i.path
            if (i.modifiedAt > now - MIN_AGE_MS) { tooNew++; continue }
            val taken = takenAt(i)
            if (!included(rule, taken)) { notIncluded++; continue }
            if (files.find(rule.id, i.path, i.sizeBytes, i.modifiedAt) != null) continue

            val sameAfterEdit = files.findByPath(rule.id, i.path).filter { !it.state.terminal }
            val verified = sameAfterEdit.firstOrNull { it.state == FileState.VERIFIED }
            val neverUploaded = sameAfterEdit.firstOrNull {
                it.state == FileState.QUEUED || it.state == FileState.FAILED || it.state == FileState.SKIPPED
            }
            if (neverUploaded != null) {
                // edited before upload: update in place
                val d = decide(rule, i)
                var row = neverUploaded.copy(
                    sizeBytes = i.sizeBytes, modifiedAt = i.modifiedAt, takenAt = taken, width = i.width,
                    height = i.height, durationMs = i.durationMs, sha256 = null, mimeType = i.mimeType,
                    route = (d as? RouteDecision.Go)?.route, sendAs = (d as? RouteDecision.Go)?.sendAs,
                    mediaStoreId = i.mediaStoreId,
                )
                files.updateDetails(row)
                if (row.state != FileState.QUEUED) files.apply(row.id, FileEvent.RetryByPerson, now)
                updated++
                continue
            }
            if (verified != null) {
                files.apply(verified.id, FileEvent.Changed, now)
                changed++
                events.add(EventKind.CHANGED, "${i.displayName} changed after upload; uploading it again", rule.id, verified.id)
            }
            val d = decide(rule, i)
            val row = newRow(rule, i, taken, d, now)
            if (row.state == FileState.SKIPPED) routed++
            pending += row
            if (pending.size >= BATCH) { newFiles += files.insertAll(pending); pending.clear() }
        }
        if (pending.isNotEmpty()) { newFiles += files.insertAll(pending); pending.clear() }

        // files that left the folder (or were deleted by the person)
        val watch = files.byRuleAndStates(
            rule.id, setOf(FileState.QUEUED, FileState.FAILED, FileState.SKIPPED, FileState.VERIFIED),
        )
        for (f in watch) {
            if (f.path in seen) continue
            if (!source.exists(f.path)) {
                files.apply(f.id, FileEvent.Vanished, now)
                gone++
                events.add(EventKind.GONE, "${f.displayName} was removed from the phone", rule.id, f.id)
            }
        }

        events.add(EventKind.SCAN_DONE, "${rule.name}: $newFiles new file${if (newFiles == 1) "" else "s"}", rule.id)
        settings.lastScanAt = now
        return ScanResult(newFiles, updated, changed, gone, tooNew, notIncluded, routed)
    }

    private fun decide(rule: RuleEntity, i: MediaItem) =
        Router.decide(i.sizeBytes, i.kind, rule.uploadAs, i.displayName, i.width, i.height, limits())

    private fun newRow(rule: RuleEntity, i: MediaItem, taken: Long, d: RouteDecision, now: Long): FileEntity {
        val go = d as? RouteDecision.Go
        return FileEntity(
            ruleId = rule.id, mediaStoreId = i.mediaStoreId, path = i.path, displayName = i.displayName,
            mimeType = i.mimeType, kind = i.kind, sizeBytes = i.sizeBytes, modifiedAt = i.modifiedAt, takenAt = taken,
            width = i.width, height = i.height, durationMs = i.durationMs,
            state = if (go != null) FileState.QUEUED else FileState.SKIPPED,
            route = go?.route, sendAs = go?.sendAs, lastError = (d as? RouteDecision.Skip)?.reason,
            queuedAt = now, createdAt = now, updatedAt = now,
        )
    }
}

/** Date from a file name such as IMG-20261101-WA0001, IMG_20261101_093012, Screenshot_20261101-093012. */
object TakenAt {
    private val re = Regex("""(?<!\d)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?:[-_ T]?([01]\d|2[0-3])([0-5]\d)([0-5]\d))?(?!\d)""")

    fun fromName(name: String, zone: ZoneId = ZoneId.systemDefault()): Long? {
        val m = re.find(name) ?: return null
        val (y, mo, d) = Triple(m.groupValues[1].toInt(), m.groupValues[2].toInt(), m.groupValues[3].toInt())
        val h = m.groupValues[4].ifEmpty { "0" }.toInt()
        val mi = m.groupValues[5].ifEmpty { "0" }.toInt()
        val s = m.groupValues[6].ifEmpty { "0" }.toInt()
        return runCatching {
            java.time.LocalDateTime.of(y, mo, d, h, mi, s).atZone(zone).toInstant().toEpochMilli()
        }.getOrNull()
    }
}
