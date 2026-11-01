package com.aakashchamola.telebackup.core.status

import com.aakashchamola.telebackup.core.db.FileStore
import com.aakashchamola.telebackup.core.db.ReviewStore
import com.aakashchamola.telebackup.core.db.RuleStore
import com.aakashchamola.telebackup.core.db.TopicStore
import com.aakashchamola.telebackup.core.model.AccountValue
import com.aakashchamola.telebackup.core.model.ControlValue
import com.aakashchamola.telebackup.core.model.FileState
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.time.Time
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.time.Instant
import java.time.ZoneId

enum class AttentionKind {
    LOGIN_EXPIRED, BIG_FILES_WAIT_ACCOUNT, ALL_FILES_LOST, NOTIFICATIONS_OFF, BATTERY_OPTIMIZED,
    BOT_PROBLEM, TOPIC_MISSING, REVIEW_WAITING, SKIPPED_RECENTLY, SETUP_NOT_DONE
}

enum class RunState { IDLE, SCANNING, UPLOADING, PAUSING, WAITING_NETWORK, STOPPED_TIME_LIMIT, CLEANING }

data class Attention(val kind: AttentionKind, val text: String, val ruleId: Long? = null, val count: Int? = null)

data class StatusSnapshot(
    val control: ControlValue,
    val delayedUntil: Long?,
    val run: RunState,
    val currentFileName: String?,
    val currentFileBytesDone: Long?,
    val currentFileBytesTotal: Long?,
    val runFilesDone: Int,
    val runFilesTotal: Int,
    val queuedCount: Int,
    val queuedBytes: Long,
    val waitingAccountCount: Int,
    val todayUploaded: Int,
    val todayFreedBytes: Long,
    val todaySkipped: Int,
    val freedBytesTotal: Long,
    val lastScanAt: Long?,
    val lastUploadAt: Long?,
    val lastStopReason: String?,
    val attention: List<Attention>,
    val onUnmeteredNetwork: Boolean,
)

/** What the phone says about permissions right now. */
data class PermissionState(val notifications: Boolean, val allFiles: Boolean, val batteryExempt: Boolean, val mediaRead: Boolean)

interface PermissionProbe {
    fun state(): PermissionState
}

interface NetworkProbe {
    fun onUnmetered(): Boolean
    fun online(): Boolean
}

/** What is running right now, kept in memory by the workers and read by the status. */
class RunTracker {
    @Volatile var run: RunState = RunState.IDLE
    @Volatile var currentFileName: String? = null
    @Volatile var bytesDone: Long? = null
    @Volatile var bytesTotal: Long? = null
    @Volatile var filesDone: Int = 0
    @Volatile var filesTotal: Int = 0
    @Volatile var pausing: Boolean = false

    /** A file started sending: the run is on, even if another run's end had set the tracker idle. */
    fun markRunning() { if (!running) run = RunState.UPLOADING }
    fun begin(total: Int) { run = RunState.UPLOADING; filesDone = 0; filesTotal = total; pausing = false }
    fun end(timeLimit: Boolean = false) {
        run = if (timeLimit) RunState.STOPPED_TIME_LIMIT else RunState.IDLE
        currentFileName = null; bytesDone = null; bytesTotal = null; pausing = false
    }
    val running get() = run == RunState.UPLOADING || run == RunState.PAUSING
}

/** Builds [StatusSnapshot] from the stores (docs/BRIDGE.md "Status"). Also owns the warnings list. */
class StatusBuilder(
    private val settings: SettingsRepository,
    private val files: FileStore,
    private val rules: RuleStore,
    private val topics: TopicStore,
    private val reviews: ReviewStore,
    private val tracker: RunTracker,
    private val perms: PermissionProbe,
    private val network: NetworkProbe,
    private val clock: Clock,
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    fun build(): StatusSnapshot {
        val now = clock.now()
        val allowAccount = settings.accountState == AccountValue.READY
        val q = files.queueCount(now, allowBot = true, allowAccount = allowAccount)
        val midnight = Instant.ofEpochMilli(now).atZone(zone).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli()
        val waitingAccount = if (allowAccount) 0 else files.waitingAccountCount()
        val run = when {
            tracker.pausing -> RunState.PAUSING
            tracker.run != RunState.IDLE -> tracker.run
            q.count > 0 && settings.controlState == ControlValue.RUNNING && settings.setupDone && !network.onUnmetered() && !settings.allowMobileData && !settings.mobileOnceUntilEmpty -> RunState.WAITING_NETWORK
            else -> RunState.IDLE
        }
        return StatusSnapshot(
            control = settings.controlState, delayedUntil = settings.delayedUntil, run = run,
            currentFileName = tracker.currentFileName, currentFileBytesDone = tracker.bytesDone, currentFileBytesTotal = tracker.bytesTotal,
            runFilesDone = tracker.filesDone, runFilesTotal = tracker.filesTotal,
            queuedCount = q.count, queuedBytes = q.bytes, waitingAccountCount = waitingAccount,
            todayUploaded = files.uploadedCountSince(midnight), todayFreedBytes = files.freedBytesSince(midnight),
            todaySkipped = files.skippedCountSince(midnight), freedBytesTotal = files.freedBytesTotal(),
            lastScanAt = settings.lastScanAt, lastUploadAt = settings.lastUploadAt, lastStopReason = settings.lastStopReason,
            attention = attention(now, waitingAccount), onUnmeteredNetwork = network.onUnmetered(),
        )
    }

    /** Things only the person can fix, most important first (docs/UI.md "Warnings"). */
    fun attention(now: Long = clock.now(), waitingAccount: Int = files.waitingAccountCount()): List<Attention> {
        val out = ArrayList<Attention>()
        val p = perms.state()
        if (!settings.setupDone) out += Attention(AttentionKind.SETUP_NOT_DONE, "Finish setup to start backing up.")
        if (!p.allFiles) out += Attention(AttentionKind.ALL_FILES_LOST, "teleBackup can't reach your folders. Backup and delete are stopped.")
        if (settings.accountState == AccountValue.EXPIRED) out += Attention(AttentionKind.LOGIN_EXPIRED, "Your Telegram account was logged out. Log in again.")
        else if (settings.accountState == AccountValue.NONE && waitingAccount > 0)
            out += Attention(AttentionKind.BIG_FILES_WAIT_ACCOUNT, "$waitingAccount big video${if (waitingAccount == 1) "" else "s"} wait for your Telegram account.", count = waitingAccount)
        if (settings.setupDone && settings.botProblem)
            out += Attention(AttentionKind.BOT_PROBLEM, "teleBackup can't post to your group. Add the bot back as admin.")
        for (r in rules.active()) {
            val missing = r.topicId?.let { topics.get(it)?.missing } ?: false
            if (missing) out += Attention(AttentionKind.TOPIC_MISSING, "${r.name}: the topic was deleted in Telegram.", ruleId = r.id)
        }
        for (rv in reviews.allWaiting()) {
            val r = rules.get(rv.ruleId) ?: continue
            out += Attention(AttentionKind.REVIEW_WAITING, "${r.name}: ${rv.fileCount} files ready to delete. Check first.", ruleId = r.id, count = rv.fileCount)
        }
        if (!p.notifications) out += Attention(AttentionKind.NOTIFICATIONS_OFF, "Notifications are off, so you won't see progress.")
        if (!p.batteryExempt) out += Attention(AttentionKind.BATTERY_OPTIMIZED, "The phone may stop backups to save battery.")
        val skippedWeek = files.skippedCountSince(now - 7 * Time.DAY)
        if (skippedWeek > 0) out += Attention(AttentionKind.SKIPPED_RECENTLY, "$skippedWeek file${if (skippedWeek == 1) "" else "s"} skipped this week.", count = skippedWeek)
        return out
    }
}

/** Holds the latest snapshot so the UI bridge and the notification can both read it. */
class StatusHub(private val builder: StatusBuilder) {
    private val flow = MutableStateFlow<StatusSnapshot?>(null)
    val state: StateFlow<StatusSnapshot?> get() = flow
    fun refresh(): StatusSnapshot = builder.build().also { flow.value = it }
    fun current(): StatusSnapshot = flow.value ?: refresh()
}
