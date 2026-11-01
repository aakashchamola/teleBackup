package com.aakashchamola.telebackup

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.secrets.KeystoreSecrets
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** The real Android Keystore: a value comes back, and the file on disk holds no plain text. */
@RunWith(AndroidJUnit4::class)
class SecretStoreTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun roundTripAndNoPlainTextOnDisk() {
        val s = KeystoreSecrets.create(ctx)
        s.clearAll()
        s.put("test.token", "123456789:AAH-notarealtokennotarealtoken000000")
        assertThat(KeystoreSecrets.create(ctx).get("test.token")).isEqualTo("123456789:AAH-notarealtokennotarealtoken000000")
        val raw = String(File(ctx.noBackupFilesDir, "secrets.bin").readBytes(), Charsets.ISO_8859_1)
        assertThat(raw).doesNotContain("AAH-")
        s.clearAll()
    }
}
