package com.aakashchamola.telebackup

import android.app.NotificationManager
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.notify.Notifier
import com.aakashchamola.telebackup.core.upload.StopReason
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith

/** The "Backing up" notification shows while a run goes on and is gone when the run ends, however the run was started. Wipes nothing. */
@RunWith(AndroidJUnit4::class)
class ProgressNotificationTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private fun shown() = nm.activeNotifications.any { it.id == Notifier.ID_PROGRESS }

    @Test
    fun showsDuringARunAndClearsWhenItEnds() {
        val sl = ServiceLocator.get(ctx)
        sl.notifier.createChannels()
        val sink = sl.progressSink()
        sink.runStarted(2, 1000)
        sink.fileStarted("photo.jpg", 500, 0, 2)
        assertThat(shown()).isTrue()
        sink.fileFinished(1, 2)
        sink.fileStarted("photo2.jpg", 500, 1, 2)
        sink.fileFinished(2, 2)
        assertThat(shown()).isTrue()           // still the run's notification until the run reports it is over
        sink.runEnded(StopReason.QUEUE_EMPTY)
        assertThat(shown()).isFalse()
        // a late update after the run ended must not bring it back
        sl.notifier.updateProgress(force = true)
        assertThat(shown()).isFalse()
        assertThat(sl.runTracker.running).isFalse()
    }
}
