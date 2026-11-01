package com.aakashchamola.telebackup.core.work

import android.content.Context
import androidx.work.*
import com.aakashchamola.telebackup.core.control.Scheduler
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import java.util.concurrent.TimeUnit

/** Starts the background jobs with WorkManager (docs/HOW_IT_WORKS.md section 1). Unique names mean one of each, ever. */
class WorkScheduler(private val context: Context, private val settings: SettingsRepository) : Scheduler {
    companion object {
        const val DAILY = "daily"
        const val SCAN_NOW = "scan-now"
        const val UPLOAD = "upload"
        const val RESUME_AT = "resume-at"
        const val CLEAN_NOW = "clean-now"
        const val RETRY_AT = "retry-at"
        const val KEY_RULE = "ruleId"
        const val KEY_REVIEW = "reviewId"
    }

    private val wm get() = WorkManager.getInstance(context)

    private fun uploadConstraints(): Constraints {
        val any = settings.allowMobileData || settings.mobileOnceUntilEmpty
        return Constraints.Builder().setRequiredNetworkType(if (any) NetworkType.CONNECTED else NetworkType.UNMETERED).build()
    }

    override fun enqueueUpload() {
        val req = OneTimeWorkRequestBuilder<UploadWorker>().setConstraints(uploadConstraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        wm.enqueueUniqueWork(UPLOAD, ExistingWorkPolicy.KEEP, req)
    }

    /** Switching mobile data on or off changes the constraint: replace the queued job (a running one finishes first). */
    fun reenqueueUploadWithNewConstraint() {
        val req = OneTimeWorkRequestBuilder<UploadWorker>().setConstraints(uploadConstraints()).build()
        wm.enqueueUniqueWork(UPLOAD, ExistingWorkPolicy.APPEND_OR_REPLACE, req)
    }

    fun enqueueUploadAfter(delayMs: Long) {
        val req = OneTimeWorkRequestBuilder<UploadWorker>().setConstraints(uploadConstraints()).setInitialDelay(delayMs, TimeUnit.MILLISECONDS).build()
        wm.enqueueUniqueWork(UPLOAD, ExistingWorkPolicy.APPEND_OR_REPLACE, req)
    }

    override fun enqueueResumeAt(delayMs: Long) {
        val req = OneTimeWorkRequestBuilder<ResumeWorker>().setInitialDelay(delayMs, TimeUnit.MILLISECONDS).build()
        wm.enqueueUniqueWork(RESUME_AT, ExistingWorkPolicy.REPLACE, req)
    }

    override fun cancelResumeAt() { wm.cancelUniqueWork(RESUME_AT) }

    override fun enqueueScanNow(ruleId: Long?) {
        val req = OneTimeWorkRequestBuilder<ScanWorker>().setInputData(workDataOf(KEY_RULE to (ruleId ?: -1L))).build()
        wm.enqueueUniqueWork(SCAN_NOW, ExistingWorkPolicy.APPEND_OR_REPLACE, req)
    }

    override fun enqueueCleanNow(reviewId: Long?) {
        val req = OneTimeWorkRequestBuilder<CleanWorker>().setInputData(workDataOf(KEY_REVIEW to (reviewId ?: -1L))).build()
        wm.enqueueUniqueWork(CLEAN_NOW, ExistingWorkPolicy.APPEND_OR_REPLACE, req)
    }

    override fun enqueueRetryAt(delayMs: Long) {
        val req = OneTimeWorkRequestBuilder<UploadWorker>().setConstraints(uploadConstraints())
            .setInitialDelay(delayMs.coerceAtLeast(30_000), TimeUnit.MILLISECONDS).build()
        wm.enqueueUniqueWork(RETRY_AT, ExistingWorkPolicy.REPLACE, req)
    }

    /** Once a day, Android picks the minute (flex of 6 hours). Safe to call on every app start. */
    fun scheduleDaily() {
        val req = PeriodicWorkRequestBuilder<DailyWorker>(24, TimeUnit.HOURS, 6, TimeUnit.HOURS)
            .setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build()).build()
        wm.enqueueUniquePeriodicWork(DAILY, ExistingPeriodicWorkPolicy.KEEP, req)
    }
}
