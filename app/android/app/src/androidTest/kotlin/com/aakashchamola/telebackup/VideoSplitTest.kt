package com.aakashchamola.telebackup

import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.clean.ScratchFiles
import com.aakashchamola.telebackup.core.upload.AndroidVideoSplitter
import com.aakashchamola.telebackup.core.upload.SplitResult
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Cuts a test video (/sdcard/Download/tb_split_test.mp4) into parts of at most 30 MB and checks each part plays and they add up. */
@RunWith(AndroidJUnit4::class)
class VideoSplitTest {
    private fun duration(f: File): Long {
        val r = MediaMetadataRetriever()
        try { r.setDataSource(f.absolutePath); return r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong() } finally { r.release() }
    }

    @Test
    fun cutsAtKeyframesAndEveryPartPlays() = runBlocking<Unit> {
        val src = File("/sdcard/Download/tb_split_test.mp4")
        assumeTrue("no test video", src.exists())
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "split/devtest")
        var last = 0L
        val res = AndroidVideoSplitter().split(src, 30_000_000L, out) { done, total -> last = done; check(done <= total) }
        try {
            val parts = (res as SplitResult.Parts).files
            assertThat(parts.size).isAtLeast(3)
            assertThat(parts.all { it.length() in 1..32_000_000L }).isTrue()
            val sum = parts.sumOf { duration(it) }
            val whole = duration(src)
            android.util.Log.i("TBTEST", "split: ${parts.size} parts ${parts.map { it.length() / 1_000_000 }} MB, durations ${parts.map { duration(it) }} vs $whole ms")
            assertThat(Math.abs(sum - whole)).isLessThan(2500L)   // nothing lost, nothing doubled
            parts.forEach { p ->
                val r = MediaMetadataRetriever()
                try {
                    r.setDataSource(p.absolutePath)
                    assertThat(r.getFrameAtTime(1_000_000L)).isNotNull()   // a picture can be read from every part: it starts on a keyframe
                    assertThat(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)).isEqualTo("yes")
                } finally { r.release() }
            }
            assertThat(last).isEqualTo(src.length())
        } finally {
            ScratchFiles.clear(out)
        }
    }
}
