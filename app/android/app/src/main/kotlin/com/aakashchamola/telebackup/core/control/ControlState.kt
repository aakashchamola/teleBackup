package com.aakashchamola.telebackup.core.control

import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.model.ControlValue
import com.aakashchamola.telebackup.core.model.EventKind
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.time.Time

/** Starts background jobs. The real one uses WorkManager; tests use a fake. */
interface Scheduler {
    fun enqueueUpload()
    fun enqueueResumeAt(delayMs: Long)
    fun cancelResumeAt()
    fun enqueueScanNow(ruleId: Long?)
    fun enqueueCleanNow(reviewId: Long?)
    fun enqueueRetryAt(delayMs: Long)
}

/** Pause, Delay and Resume (docs/HOW_IT_WORKS.md section 6). The state lives in settings so it survives restarts. */
class ControlState(
    private val settings: SettingsRepository,
    private val events: EventLog,
    private val clock: Clock,
    private val scheduler: Scheduler,
) {
    fun pause() {
        settings.controlState = ControlValue.PAUSED
        settings.delayedUntil = null
        scheduler.cancelResumeAt()
        events.add(EventKind.PAUSED, "Paused")
    }

    fun delay(minutes: Int) {
        require(minutes in 15..1440) { "Delay must be 15 minutes to 24 hours" }
        val until = clock.now() + minutes * Time.MINUTE
        settings.controlState = ControlValue.DELAYED
        settings.delayedUntil = until
        scheduler.enqueueResumeAt(minutes * Time.MINUTE)
        events.add(EventKind.DELAYED, "Paused for ${describe(minutes)}")
    }

    fun resume() {
        settings.controlState = ControlValue.RUNNING
        settings.delayedUntil = null
        scheduler.cancelResumeAt()
        scheduler.enqueueUpload()
        events.add(EventKind.RESUMED, "Resumed")
    }

    /** The delay timer fired. Does nothing if the person already resumed or paused again. */
    fun onResumeAtFired() {
        if (settings.controlState == ControlValue.DELAYED && (settings.delayedUntil ?: 0L) <= clock.now() + Time.MINUTE) resume()
    }

    companion object {
        fun describe(minutes: Int): String =
            if (minutes % 60 == 0) "${minutes / 60} hour${if (minutes == 60) "" else "s"}" else "$minutes minutes"
    }
}
