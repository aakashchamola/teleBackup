package com.aakashchamola.telebackup

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.model.FileState
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Starts the app's own scan and upload workers and stays alive while they run, so the test process (which is the app's process)
 * is not killed in the middle. Logs progress (tag BACKUPRUN). Only what the rules allow is sent; nothing is deleted.
 */
@RunWith(AndroidJUnit4::class)
class RunBackupTest {
    private fun log(m: String) { Log.i("BACKUPRUN", m) }

    @Test
    fun scanAndUploadUntilDone() {
        val sl = ServiceLocator.get(InstrumentationRegistry.getInstrumentation().targetContext)
        assumeTrue("not set up", sl.settings.setupDone && sl.settings.chatId != null)
        val startedAt = sl.clock.now()
        sl.scheduler.enqueueScanNow(null)
        var uploadRequested = false
        val end = System.currentTimeMillis() + 90 * 60_000L
        var idleRounds = 0
        while (System.currentTimeMillis() < end) {
            Thread.sleep(10_000)
            val all = sl.fileStore.page(null, null, null, 100_000)
            val by = all.groupingBy { it.state }.eachCount()
            val queued = (by[FileState.QUEUED] ?: 0) + (by[FileState.UPLOADING] ?: 0) + (by[FileState.FAILED] ?: 0)
            log("files=${all.size} $by")
            val scanned = (sl.settings.lastScanAt ?: 0L) >= startedAt
            if (scanned && !uploadRequested) { sl.scheduler.enqueueUpload(); uploadRequested = true; log("upload requested") }
            if (uploadRequested && queued == 0) { if (++idleRounds >= 3) break } else idleRounds = 0
        }
        log("DONE")
    }
}
