package com.aakashchamola.telebackup

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.model.MediaTypes
import com.aakashchamola.telebackup.core.model.RuleMode
import com.aakashchamola.telebackup.core.model.StartMode
import com.aakashchamola.telebackup.core.model.UploadAs
import com.aakashchamola.telebackup.core.telegram.bot.ApiResult
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Sets up the owner's gallery (DCIM/Camera): topics "Gallery photos", "Gallery videos" and "Documents", and two UPLOAD ONLY rules
 * that start from the oldest file, then starts the first scan. Safe to run again: what exists is kept. Deletes nothing, wipes nothing.
 */
@RunWith(AndroidJUnit4::class)
class GallerySetupTest {
    @Test
    fun setUpGalleryRules() = kotlinx.coroutines.runBlocking<Unit> {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val sl = ServiceLocator.get(ctx)
        val chat = sl.settings.chatId
        assumeTrue("Telegram is not connected", chat != null && sl.settings.setupDone)

        suspend fun topic(name: String): Long =
            sl.topicStore.list(chat!!).firstOrNull { it.name == name && !it.missing }?.threadId
                ?: (sl.botSetup.createTopic(name) as ApiResult.Ok).value.threadId

        val photos = topic("Gallery photos")
        val videos = topic("Gallery videos")
        val docs = topic("Documents")
        sl.settings.documentsTopicId = docs

        fun rule(name: String, types: MediaTypes, topicId: Long, sort: Boolean) {
            if (sl.rules.active().any { it.name == name }) return
            sl.rules.save(
                RuleEntity(
                    name = name, folderPath = "DCIM/Camera/", mediaTypes = types, topicId = topicId, uploadAs = UploadAs.MEDIA,
                    mode = RuleMode.UPLOAD_ONLY, startMode = StartMode.EVERYTHING, dryRun = true, sortDocuments = sort,
                ),
            )
        }
        rule("Gallery photos", MediaTypes.PHOTOS, photos, sort = true)
        rule("Gallery videos", MediaTypes.VIDEOS, videos, sort = false)
        sl.scheduler.enqueueScanNow(null)
    }
}
