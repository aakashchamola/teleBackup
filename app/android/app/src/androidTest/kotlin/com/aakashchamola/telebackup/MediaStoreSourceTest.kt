package com.aakashchamola.telebackup

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.model.MediaTypes
import com.aakashchamola.telebackup.core.scan.MediaStoreSource
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith

/** Adds an image through MediaStore into Pictures/teleBackupTest/ and checks the scanner source finds it with the right facts. */
@RunWith(AndroidJUnit4::class)
class MediaStoreSourceTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun findsAFreshlyAddedImage() {
        val name = "source-test-${System.nanoTime()}.jpg"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/teleBackupTest")
        }
        val uri = ctx.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
        try {
            ctx.contentResolver.openOutputStream(uri)!!.use { it.write(ByteArray(2048)) }
            val items = MediaStoreSource(ctx).list("Pictures/teleBackupTest/", false, MediaTypes.PHOTOS)
            val hit = items.firstOrNull { it.displayName == name }
            assertThat(hit).isNotNull()
            assertThat(hit!!.sizeBytes).isEqualTo(2048)
            assertThat(hit.path).isEqualTo(Environment.getExternalStorageDirectory().absolutePath + "/Pictures/teleBackupTest/" + name)
        } finally {
            ctx.contentResolver.delete(uri, null, null)   // test cleanup of the test's own file
        }
    }
}
