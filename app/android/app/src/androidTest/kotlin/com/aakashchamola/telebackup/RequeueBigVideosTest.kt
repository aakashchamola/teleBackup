package com.aakashchamola.telebackup

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.di.ServiceLocator
import org.junit.Test
import org.junit.runner.RunWith

/**
 * One-off dev tool: videos marked "Too big for Telegram (over 2 GB)" before the app could cut videos into parts are forgotten
 * (they hold no upload state), and the rules are scanned again so they come back queued. Touches only those rows.
 */
@RunWith(AndroidJUnit4::class)
class RequeueBigVideosTest {
    @Test
    fun requeue() {
        val sl = ServiceLocator.get(InstrumentationRegistry.getInstrumentation().targetContext)
        val db = sl.db.openHelper.writableDatabase
        db.execSQL("DELETE FROM files WHERE state = 'SKIPPED' AND lastError LIKE 'Too big for Telegram%' AND route IS NULL AND tgMessageId IS NULL")
        sl.rules.active().forEach { sl.scanner.scan(it) }
        val big = sl.fileStore.page(null, null, null, 100_000).filter { it.partCount > 1 }
        Log.i("TBTEST", "requeued big videos: ${big.map { "${it.displayName} parts=${it.partCount} state=${it.state} route=${it.route}" }}")
        sl.scheduler.enqueueUpload()
        Thread.sleep(3000)
    }
}
