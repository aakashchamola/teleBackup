package com.aakashchamola.telebackup

import android.app.Application
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.log.Tlog

/** Starts the core: notification channels, the daily job, and a check that unfinished work is scheduled. */
class TeleBackupApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Thread {
            try {
                val sl = ServiceLocator.get(this)
                sl.notifier.createChannels()
                if (sl.settings.setupDone) {
                    sl.scheduler.scheduleDaily()
                    if (sl.fileStore.queueCount(sl.clock.now(), true, true).count > 0) sl.scheduler.enqueueUpload()
                }
            } catch (e: Exception) {
                Tlog.e("startup check failed", e)
            }
        }.start()
    }
}
