package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.secrets.FileSecrets
import com.aakashchamola.telebackup.core.secrets.KeystoreSecrets
import com.aakashchamola.telebackup.core.secrets.SecretBox
import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import javax.crypto.KeyGenerator

class SecretsTest {
    private fun key() = KeyGenerator.getInstance("AES").also { it.init(256) }.generateKey()
    private fun tmp() = File.createTempFile("secrets", ".bin").also { it.delete(); it.deleteOnExit() }

    @Test fun sealAndOpenRoundTrip() {
        val box = SecretBox(key())
        val sealed = box.seal("hello".toByteArray())
        assertThat(String(box.open(sealed))).isEqualTo("hello")
        assertThat(box.seal("hello".toByteArray())).isNotEqualTo(sealed)   // new IV each time
    }

    @Test fun anotherKeyCannotOpen() {
        val sealed = SecretBox(key()).seal("hello".toByteArray())
        assertThrows(Exception::class.java) { SecretBox(key()).open(sealed) }
    }

    @Test fun storeKeepsValuesAndNeverWritesThemInPlain() {
        val f = tmp(); val k = key()
        val s = FileSecrets(f, SecretBox(k))
        s.put("bot.token", "123456789:AAH-abcdefghijklmnopqrstuvwxyz0123456")
        s.put("account.apiHash", "0123456789abcdef0123456789abcdef")
        s.put("weird", "line1\nline2\ttab\\slash")
        val raw = String(f.readBytes(), Charsets.ISO_8859_1)
        assertThat(raw).doesNotContain("AAH-")
        assertThat(raw).doesNotContain("0123456789abcdef")
        val again = FileSecrets(f, SecretBox(k))
        assertThat(again.get("bot.token")).isEqualTo("123456789:AAH-abcdefghijklmnopqrstuvwxyz0123456")
        assertThat(again.get("weird")).isEqualTo("line1\nline2\ttab\\slash")
        assertThat(again.get("missing")).isNull()
    }

    @Test fun removeAndClear() {
        val f = tmp(); val s = FileSecrets(f, SecretBox(key()))
        s.put("a", "1"); s.put("b", "2")
        s.remove("a")
        assertThat(s.get("a")).isNull(); assertThat(s.get("b")).isEqualTo("2")
        s.clearAll()
        assertThat(f.length()).isEqualTo(0)
        assertThat(s.get("b")).isNull()
    }

    @Test fun lostKeyReadsAsEmptyInsteadOfCrashing() {
        val f = tmp()
        FileSecrets(f, SecretBox(key())).put("a", "1")
        assertThat(FileSecrets(f, SecretBox(key())).get("a")).isNull()
    }

    @Test fun randomKeysAreLongAndDifferent() {
        val a = KeystoreSecrets.randomKeyHex(); val b = KeystoreSecrets.randomKeyHex()
        assertThat(a).hasLength(64); assertThat(a).isNotEqualTo(b)
    }
}
