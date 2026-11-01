package com.aakashchamola.telebackup

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Environment
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.db.TopicEntity
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.model.FileState
import com.aakashchamola.telebackup.core.model.RuleMode
import com.aakashchamola.telebackup.core.model.StartMode
import com.aakashchamola.telebackup.core.model.TopicSource
import com.aakashchamola.telebackup.core.secrets.SecretNames
import com.aakashchamola.telebackup.core.telegram.bot.ApiResult
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream
import kotlin.random.Random

/**
 * The M1 "done when", on the phone, through the real app code: a test photo is scanned, sent by the bot to a topic of the
 * THROWAWAY group, its reply checked, and only then deleted through the delete gate (review approved first).
 * Needs `-e botToken -e chatId`; skips itself without them. It wipes the app's own database first, so run it on a dev install only.
 * Only touches Pictures/teleBackupE2E/ (its own file).
 */
@RunWith(AndroidJUnit4::class)
class BotEndToEndTest {
    @Test
    fun photoGoesToTheTopicIsCheckedThenDeleted() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        val token = args.getString("botToken"); val chat = args.getString("chatId")?.toLongOrNull()
        assumeTrue("needs -e botToken and -e chatId", token != null && chat != null)
        assumeTrue("needs All files access", Environment.isExternalStorageManager())
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val sl = ServiceLocator.get(ctx)
        assertThat(sl.debugBuild).isTrue()

        // clean slate
        sl.db.clearAllTables(); sl.secrets.clearAll()
        val me = sl.botSetup.checkToken(token!!) as ApiResult.Ok
        sl.secrets.put(SecretNames.BOT_TOKEN, token)
        sl.settings.chatId = chat; sl.settings.chatTitle = "E2E"
        sl.settings.setupDoneAt = sl.clock.now()
        sl.settings.allowBotOnlyDelete = true   // the D1 answer is "no" by default; this test DB says yes so the delete path can be seen
        sl.settings.timeWarp = true             // a retention "day" is a minute
        val topic = sl.botSetup.createTopic("E2E ${System.currentTimeMillis() % 100000}") as ApiResult.Ok

        // a real JPEG of its own, 10 minutes old (the scanner skips files younger than 2 minutes)
        val dir = File(Environment.getExternalStorageDirectory(), "Pictures/teleBackupE2E").also { it.mkdirs() }
        val f = File(dir, "e2e-${System.currentTimeMillis()}.jpg")
        val bmp = Bitmap.createBitmap(1600, 1200, Bitmap.Config.ARGB_8888)
        val rnd = Random(7)
        for (y in 0 until 1200 step 4) for (x in 0 until 1600 step 4) bmp.setPixel(x, y, Color.rgb(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)))
        FileOutputStream(f).use { bmp.compress(Bitmap.CompressFormat.JPEG, 80, it) }
        f.setLastModified(System.currentTimeMillis() - 10 * 60_000)

        var savedRuleId: Long? = null
        try {
            val rule = sl.rules.save(
                RuleEntity(
                    name = "E2E", folderPath = "Pictures/teleBackupE2E/", topicId = topic.value.threadId,
                    mode = RuleMode.UPLOAD_AND_DELETE, retentionDays = 1, startMode = StartMode.EVERYTHING,
                    dryRun = true, deleteWarningAcceptedAt = sl.clock.now(),
                ),
            )

            // scan finds the file (it is not in MediaStore yet: the file-system fallback has to find it)
            savedRuleId = rule.id
            val scan = sl.scanner.scan(rule)
            assertThat(scan.newFiles).isEqualTo(1)

            // upload by the bot, reply checked
            val outcome = sl.uploadLoop(sl.progressSink()).run { false }
            assertThat(outcome.filesDone).isEqualTo(1)
            val row = sl.fileStore.findByPath(rule.id, f.absolutePath).single()
            assertThat(row.state).isEqualTo(FileState.VERIFIED)
            assertThat(row.tgChatId).isEqualTo(chat)
            assertThat(row.tgThreadId).isEqualTo(topic.value.threadId)
            assertThat(row.tgMessageId).isNotNull()
            assertThat(f.exists()).isTrue()   // nothing deleted before the review

            // retention passes (a minute under time warp), the cleaner makes a review and does NOT delete
            Thread.sleep(65_000)
            val first = sl.cleaner().run(true)
            assertThat(first.reviewsCreated).isEqualTo(1)
            assertThat(first.deleted).isEqualTo(0)
            assertThat(f.exists()).isTrue()

            // the person approves; now (and only now) it is deleted
            val review = sl.reviewStore.waitingFor(rule.id)!!
            sl.reviews.approve(review.id)
            val second = sl.cleaner().run(true, review.id)
            assertThat(second.deleted).isEqualTo(1)
            assertThat(f.exists()).isFalse()
            assertThat(sl.fileStore.get(row.id)!!.state).isEqualTo(FileState.DELETED)

        } finally {
            // leave the dev install as a person would want it: connected to the throwaway group, no rules, deletes at their safe defaults
            savedRuleId?.let { sl.rules.softDelete(it) }
            sl.settings.allowBotOnlyDelete = false
            sl.settings.timeWarp = false
            File(Environment.getExternalStorageDirectory(), "Pictures/teleBackupE2E").deleteRecursively()
        }
        assertThat(me.value.username).isNotEmpty()
    }
}
