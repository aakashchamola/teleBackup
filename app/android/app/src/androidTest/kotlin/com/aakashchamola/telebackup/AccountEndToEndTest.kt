package com.aakashchamola.telebackup

import android.os.Environment
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.model.AccountCheck
import com.aakashchamola.telebackup.core.model.AccountValue
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.secrets.SecretNames
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.account.AccountAuth
import com.aakashchamola.telebackup.core.telegram.account.TdFetch
import com.aakashchamola.telebackup.core.telegram.bot.ApiResult
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Needs a logged-in account on this install and the throwaway group saved in the app (the owner does both in Settings).
 * Uses only its own files in Pictures/teleBackupE2E/ and posts only to the saved group, in a new topic. Wipes nothing.
 * Results go to logcat, tag TBTEST.
 */
@RunWith(AndroidJUnit4::class)
class AccountEndToEndTest {
    private fun log(m: String) { Log.i("TBTEST", m) }
    private val dir = File(Environment.getExternalStorageDirectory(), "Pictures/teleBackupE2E")

    @Test
    fun accountSendsAndRefetches() = runBlocking<Unit> {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val sl = ServiceLocator.get(ctx)
        assumeTrue("account not logged in", sl.settings.accountState == AccountValue.READY)
        val chat = sl.settings.chatId!!
        val auth = sl.accountAuth!!
        val gw = sl.tdGateway!!
        assertThat(auth.ensureReady()).isEqualTo(AccountAuth.Readiness.Ready)
        log("account ready as ${sl.settings.accountName}")

        val topic = sl.botSetup.createTopic("Account test ${System.currentTimeMillis() % 100000}") as ApiResult.Ok
        val thread = topic.value.threadId

        // Q6: the bot posts, the account fetches it again
        val small = File(dir, "small_01.jpg")
        val botApi = sl.botApi()
        val botSent = botApi.sendFile(
            SendJob(chat, thread, small.absolutePath, small.name, "image/jpeg", SendAs.DOCUMENT, "bot post", small.length()),
        ) { _, _ -> } as ApiResult.Ok
        val sm = botSent.value
        log("bot posted message ${sm.messageId} size ${sm.size} uniq ${sm.fileUniqueId}")
        val fetched = gw.fetch(chat, sm.messageId)
        log("account fetch of bot message: $fetched")
        assertThat(fetched).isInstanceOf(TdFetch.Found::class.java)
        val f = (fetched as TdFetch.Found).message
        assertThat(f.size).isEqualTo(small.length())
        assertThat(f.messageId).isEqualTo(sm.messageId)
        assertThat(f.fileUniqueId).isEqualTo(sm.fileUniqueId)
        assertThat(f.threadId).isEqualTo(thread)
        // a message id that does not exist
        val missing = gw.fetch(chat, sm.messageId + 5000)
        log("fetch of a made-up id: $missing")

        // big file as the account (75 MB, over the bot's 50 MB)
        val big = File(dir, "clip_75MB.mp4")
        val start = System.currentTimeMillis()
        var lastLog = 0L
        val res = gw.send(
            SendJob(chat, thread, big.absolutePath, big.name, "video/mp4", SendAs.DOCUMENT, "account post", big.length()),
        ) { sent, total ->
            val now = System.currentTimeMillis()
            if (now - lastLog > 3000) { lastLog = now; log("uploading $sent / $total") }
        }
        val secs = (System.currentTimeMillis() - start) / 1000.0
        log("account send finished in ${secs}s: $res")
        assertThat(res).isInstanceOf(SendResult.Sent::class.java)
        val sent = (res as SendResult.Sent).message
        assertThat(sent.size).isEqualTo(big.length())
        log("account message id ${sent.messageId} thread ${sent.threadId} uniq ${sent.fileUniqueId}; MB/s ${big.length() / 1e6 / secs}")
        assertThat(sent.threadId).isEqualTo(thread)

        // the strong check on the account's own big message
        val again = gw.fetch(chat, sent.messageId)
        assertThat(again).isInstanceOf(TdFetch.Found::class.java)
        assertThat((again as TdFetch.Found).message.size).isEqualTo(big.length())
        log("PASS")
    }

    /** F: SHA-256 speed, then a 1 GB send as the account. The PC switches Wi-Fi and mobile data off when the log shows 300 MB sent. */
    @Test
    fun bigFileHashAndResume() = runBlocking<Unit> {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val sl = ServiceLocator.get(ctx)
        assumeTrue("account not logged in", sl.settings.accountState == AccountValue.READY)
        val big = File(dir, "big_1GB.bin")
        assumeTrue("no 1 GB file", big.exists())
        val h0 = System.currentTimeMillis()
        val sha = com.aakashchamola.telebackup.core.scan.FileHasher().sha256(big.absolutePath)
        log("SHA-256 of ${big.length()} bytes took ${(System.currentTimeMillis() - h0) / 1000.0}s ($sha)")

        val chat = sl.settings.chatId!!
        assertThat(sl.accountAuth!!.ensureReady()).isEqualTo(AccountAuth.Readiness.Ready)
        val topic = sl.botSetup.createTopic("1GB test ${System.currentTimeMillis() % 100000}") as ApiResult.Ok
        val start = System.currentTimeMillis()
        var lastLog = 0L
        var lastSent = 0L
        val res = sl.tdGateway!!.send(
            SendJob(chat, topic.value.threadId, big.absolutePath, big.name, "application/octet-stream", SendAs.DOCUMENT, "1 GB", big.length()),
        ) { sent, total ->
            lastSent = sent
            val now = System.currentTimeMillis()
            if (now - lastLog > 2000) { lastLog = now; log("uploading $sent / $total") }
        }
        log("1 GB send finished in ${(System.currentTimeMillis() - start) / 1000.0}s: $res")
        assertThat(res).isInstanceOf(SendResult.Sent::class.java)
        assertThat((res as SendResult.Sent).message.size).isEqualTo(big.length())
        log("PASS1GB")
    }
}
