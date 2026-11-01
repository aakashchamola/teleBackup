package com.aakashchamola.telebackup.core.work

import android.content.Context
import android.content.pm.ServiceInfo
import androidx.work.*
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.ControlValue
import com.aakashchamola.telebackup.core.model.EventKind
import com.aakashchamola.telebackup.core.notify.Notifier
import com.aakashchamola.telebackup.core.time.Time
import com.aakashchamola.telebackup.core.upload.StopReason
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** Scans every enabled rule (or one) and queues new files. Returns how many files were queued. */
internal suspend fun runScan(sl: ServiceLocator, ruleId: Long?): Int = withContext(Dispatchers.IO) {
    val rules = if (ruleId != null && ruleId > 0) listOfNotNull(sl.ruleStore.get(ruleId)) else sl.ruleStore.active()
    var queued = 0
    sl.runTracker.run = com.aakashchamola.telebackup.core.status.RunState.SCANNING
    try {
        for (r in rules) queued += sl.scanner.scan(r).newFiles
    } finally {
        sl.runTracker.run = com.aakashchamola.telebackup.core.status.RunState.IDLE
    }
    queued
}

/** Checks the all-files permission at the start of every worker. False means: nothing may be scanned, uploaded or deleted. */
internal fun permissionOk(sl: ServiceLocator): Boolean {
    val ok = sl.permissions.state().allFiles
    sl.cleaner().updateBlock(ok)
    if (!ok) sl.raiseAttention()
    return ok
}

class ScanWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val sl = ServiceLocator.get(applicationContext)
        sl.notifier.createChannels()
        if (!permissionOk(sl)) return Result.success()
        val queued = runScan(sl, inputData.getLong(WorkScheduler.KEY_RULE, -1L))
        sl.statusHub.refresh()
        if (queued > 0 || sl.fileStore.queueCount(sl.clock.now(), true, true).count > 0) sl.scheduler.enqueueUpload()
        return Result.success()
    }
}

/** Once a day: scan, then delete what is due, then forget old history. */
class DailyWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val sl = ServiceLocator.get(applicationContext)
        sl.notifier.createChannels()
        if (!sl.settings.setupDone) return Result.success()
        if (!permissionOk(sl)) return Result.success()
        runScan(sl, null)
        withContext(Dispatchers.IO) {
            sl.cleaner().run(sl.permissions.state().allFiles)
            sl.eventStore.prune(sl.clock.now() - 90 * Time.DAY)
        }
        sl.raiseAttention()
        if (sl.fileStore.queueCount(sl.clock.now(), true, true).count > 0) sl.scheduler.enqueueUpload()
        return Result.success()
    }
}

class CleanWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val sl = ServiceLocator.get(applicationContext)
        sl.notifier.createChannels()
        val ok = permissionOk(sl)
        if (!ok) return Result.success()
        val reviewId = inputData.getLong(WorkScheduler.KEY_REVIEW, -1L).takeIf { it > 0 }
        withContext(Dispatchers.IO) { sl.cleaner().run(ok, reviewId) }
        sl.statusHub.refresh()
        return Result.success()
    }
}

class ResumeWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val sl = ServiceLocator.get(applicationContext)
        withContext(Dispatchers.IO) { sl.control.onResumeAtFired() }
        if (sl.settings.controlState == ControlValue.RUNNING) sl.notifier.cancelControl()
        sl.statusHub.refresh()
        return Result.success()
    }
}

/** The upload run, as a foreground service of type dataSync (docs/HOW_IT_WORKS.md section 5). */
class UploadWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    private val sl get() = ServiceLocator.get(applicationContext)

    override suspend fun getForegroundInfo(): ForegroundInfo =
        ForegroundInfo(Notifier.ID_PROGRESS, sl.notifier.progress(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)

    override suspend fun doWork(): Result {
        val sl = sl
        sl.notifier.createChannels()
        if (sl.settings.chatId == null) return Result.success()
        if (!permissionOk(sl)) return Result.success()
        if (sl.settings.controlState == ControlValue.PAUSED || (sl.settings.controlState == ControlValue.DELAYED && (sl.settings.delayedUntil ?: 0) > sl.clock.now())) {
            sl.notifier.showControlState(sl.fileStore.queueCount(sl.clock.now(), true, true).count)
            return Result.success()
        }
        try {
            setForeground(getForegroundInfo())
        } catch (e: IllegalStateException) {
            // Android 12+ refuses a background start when the app has no battery exemption
            sl.events.add(EventKind.RUN_STOPPED, "Backup could not start in the background (fgs_not_allowed)")
            sl.settings.lastStopReason = "fgs_not_allowed"
            return Result.retry()
        }
        sl.notifier.cancelControl()
        var timeLimit = false
        try {
            val outcome = withContext(Dispatchers.IO) { sl.uploadLoop(sl.progressSink()).run { isStopped } }
            Tlog.i("upload run ended: ${outcome.reason}, ${outcome.filesDone} files")
            sl.events.add(EventKind.RUN_STOPPED, "Upload run ended: ${outcome.reason.name.lowercase().replace('_', ' ')} (${outcome.filesDone} files)")
            return when (outcome.reason) {
                StopReason.NO_INTERNET -> Result.retry()
                else -> Result.success()
            }
        } catch (e: CancellationException) {
            timeLimit = Build_stopReasonIsTimeout(this)
            withContext(NonCancellable) {
                sl.events.add(EventKind.RUN_STOPPED, if (timeLimit) "Stopped by Android's time limit for background work" else "Upload stopped (network lost or the phone stopped it)")
                sl.settings.lastStopReason = if (timeLimit) "time_limit" else "network"
                if (timeLimit) sl.scheduler.enqueueUploadAfter(Time.HOUR)
            }
            throw e
        } finally {
            withContext(NonCancellable) {
                sl.runTracker.end(timeLimit)
                afterRun(sl)
            }
        }
    }

    private fun afterRun(sl: ServiceLocator) {
        val now = sl.clock.now()
        sl.fileStore.earliestRetryAt()?.let { at -> if (at > now) sl.scheduler.enqueueRetryAt(at - now) }
        if (sl.settings.controlState != ControlValue.RUNNING) {
            sl.notifier.showControlState(sl.fileStore.queueCount(now, true, true).count)
        }
        sl.raiseAttention()
        sl.statusHub.refresh()
    }
}

/** True when WorkManager says Android's foreground time limit stopped the run (Android 15 and later). */
private fun Build_stopReasonIsTimeout(w: ListenableWorker): Boolean =
    android.os.Build.VERSION.SDK_INT >= 35 && w.stopReason == WorkInfo.STOP_REASON_FOREGROUND_SERVICE_TIMEOUT
