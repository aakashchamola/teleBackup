package com.aakashchamola.telebackup

import android.os.Environment
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.clean.AndroidFileDeleter
import com.aakashchamola.telebackup.core.clean.DeleteOutcome
import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.model.FileKind
import com.google.common.truth.Truth.assertThat
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Deletes a file this test made itself, inside Pictures/teleBackupTest/. Needs "All files access" granted to teleBackup
 * (the test skips itself if it is not). It refuses to touch anything outside the test folder.
 */
@RunWith(AndroidJUnit4::class)
class FileDeleterTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private val dir = File(Environment.getExternalStorageDirectory(), "Pictures/teleBackupTest")

    private fun entity(f: File) = FileEntity(
        ruleId = 1, path = f.absolutePath, displayName = f.name, mimeType = "image/jpeg", kind = FileKind.PHOTO,
        sizeBytes = f.length(), modifiedAt = f.lastModified(), takenAt = f.lastModified(),
    )

    @Test
    fun deletesATestFileAndReportsTheFreedBytes() {
        assumeTrue("All files access is not granted", Environment.isExternalStorageManager())
        dir.mkdirs()
        val f = File(dir, "deleter-test-${System.nanoTime()}.jpg").also { it.writeBytes(ByteArray(1234)) }
        val out = AndroidFileDeleter(ctx).removeFromPhone(entity(f))
        assertThat(out).isEqualTo(DeleteOutcome.Deleted(1234))
        assertThat(f.exists()).isFalse()
    }

    @Test
    fun aFileThatIsAlreadyGoneIsAFailureNotASuccess() {
        val f = File(dir, "never-existed.jpg")
        val out = AndroidFileDeleter(ctx).removeFromPhone(entity(f).copy(sizeBytes = 1))
        assertThat(out).isInstanceOf(DeleteOutcome.Failed::class.java)
    }
}
