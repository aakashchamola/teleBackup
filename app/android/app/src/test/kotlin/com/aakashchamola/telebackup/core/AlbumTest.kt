package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.scan.DocumentClassifier
import com.aakashchamola.telebackup.core.scan.Scanner
import com.aakashchamola.telebackup.core.telegram.*
import com.aakashchamola.telebackup.core.upload.StopReason
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.time.ZoneId

/** Albums (photos and videos of one day sent together) and photos of documents going to their own topic. */
class AlbumTest {
    private val day = Fx.DAY
    private fun bot() = FakeSender.ok().also { it.albumsSupported = true }
    private fun World.run() = runBlocking { loop().run { false } }

    @Test fun photosOfOneDayGoTogetherInAlbumsOfTenOldestFirst() {
        val b = bot(); val w = World(b)
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        // 12 photos 20 days ago (a minute apart), 3 photos 10 days ago, 1 photo 5 days ago
        val items = (1..12).map { w.photo(it, ageMs = 20 * day - it * 60_000L) } +
            (13..15).map { w.photo(it, ageMs = 10 * day - it * 60_000L) } + w.photo(16, ageMs = 5 * day)
        w.scanWith(r, *items.toTypedArray())
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.QUEUE_EMPTY)
        assertThat(out.filesDone).isEqualTo(16)
        assertThat(b.albums.map { it.size }).containsExactly(10, 2, 3).inOrder()
        assertThat(b.jobs.map { it.displayName }).containsExactly("IMG_16.jpg")   // the lone photo goes alone
        // oldest first: the first album holds the day's earliest photos, in order
        assertThat(b.albums[0].map { it.displayName }).containsExactly(
            "IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg", "IMG_5.jpg", "IMG_6.jpg", "IMG_7.jpg", "IMG_8.jpg", "IMG_9.jpg", "IMG_10.jpg",
        ).inOrder()
        assertThat(w.all().all { it.state == FileState.VERIFIED }).isTrue()
        assertThat(b.albums.flatten().all { it.threadId == 5L }).isTrue()
    }

    @Test fun photosAndSmallVideosOfADayShareAnAlbum() {
        val b = bot(); val w = World(b)
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.video(2, ageMs = 3 * day - 60_000, size = 30_000_000), w.photo(3, ageMs = 3 * day - 120_000))
        w.run()
        assertThat(b.albums).hasSize(1)
        assertThat(b.albums[0].map { it.sendAs }).containsExactly(SendAs.PHOTO, SendAs.VIDEO, SendAs.PHOTO).inOrder()
    }

    @Test fun groupingOffSendsOneByOne() {
        val b = bot(); val w = World(b)
        w.settings.groupByDay = false
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.photo(2, ageMs = 3 * day - 60_000))
        w.run()
        assertThat(b.albums).isEmpty()
        assertThat(b.jobs).hasSize(2)
    }

    @Test fun anAlbumNeverMixesTopics() {
        val b = bot(); val w = World(b)
        w.settings.documentsTopicId = 9
        val r = w.rule(uploadAs = UploadAs.MEDIA, sortDocuments = true)
        val classifier = DocumentClassifier { it.contains("DOC") }
        val sc = Scanner(w.media, w.files, w.settings, w.events, w.clock, ZoneId.of("UTC"), classifier)
        listOf(
            w.photo(1, ageMs = 2 * day, name = "IMG_1.jpg"), w.photo(2, ageMs = 2 * day - 60_000, name = "DOC_2.jpg"),
            w.photo(3, ageMs = 2 * day - 120_000, name = "IMG_3.jpg"), w.photo(4, ageMs = 2 * day - 180_000, name = "DOC_4.jpg"),
        ).forEach { w.media.add(it) }
        sc.scan(r); w.syncDisk()
        w.run()
        assertThat(b.albums).hasSize(2)
        val (docs, others) = b.albums.partition { a -> a.all { it.threadId == 9L } }
        assertThat(docs.single().map { it.displayName }).containsExactly("DOC_2.jpg", "DOC_4.jpg").inOrder()
        assertThat(others.single().map { it.displayName }).containsExactly("IMG_1.jpg", "IMG_3.jpg").inOrder()
        assertThat(others.single().all { it.threadId == 5L }).isTrue()
    }

    @Test fun documentSortingIsOffUnlessTheRuleAsksForIt() {
        val b = bot(); val w = World(b)
        w.settings.documentsTopicId = 9
        val off = w.rule(uploadAs = UploadAs.MEDIA)   // sortDocuments = false
        val sc = Scanner(w.media, w.files, w.settings, w.events, w.clock, ZoneId.of("UTC")) { true }   // would call everything a document
        w.media.add(w.photo(1, ageMs = 2 * day)); sc.scan(off)
        assertThat(w.all().single().topicId).isNull()
        // and without a Documents topic chosen, even a rule that asks for it sorts nothing
        val w2 = World(bot())
        val on = w2.rule(uploadAs = UploadAs.MEDIA, sortDocuments = true)
        val sc2 = Scanner(w2.media, w2.files, w2.settings, w2.events, w2.clock, ZoneId.of("UTC")) { true }
        w2.media.add(w2.photo(1, ageMs = 2 * day)); sc2.scan(on)
        assertThat(w2.all().single().topicId).isNull()
    }

    @Test fun onlyPhotosAreSortedNotVideos() {
        val w = World(bot())
        w.settings.documentsTopicId = 9
        val r = w.rule(uploadAs = UploadAs.MEDIA, sortDocuments = true)
        val sc = Scanner(w.media, w.files, w.settings, w.events, w.clock, ZoneId.of("UTC")) { true }
        w.media.add(w.photo(1, ageMs = 2 * day)); w.media.add(w.video(2, ageMs = 2 * day))
        sc.scan(r)
        assertThat(w.all().first { it.kind == FileKind.PHOTO }.topicId).isEqualTo(9)
        assertThat(w.all().first { it.kind == FileKind.VIDEO }.topicId).isNull()
    }

    @Test fun aBrokenClassifierNeverBlocksTheScan() {
        val w = World(bot())
        w.settings.documentsTopicId = 9
        val r = w.rule(uploadAs = UploadAs.MEDIA, sortDocuments = true)
        val sc = Scanner(w.media, w.files, w.settings, w.events, w.clock, ZoneId.of("UTC")) { throw IllegalStateException("model missing") }
        w.media.add(w.photo(1, ageMs = 2 * day))
        assertThat(sc.scan(r).newFiles).isEqualTo(1)
        assertThat(w.all().single().topicId).isNull()
    }

    @Test fun oneBadFileInAnAlbumFallsBackToOneByOne() {
        val b = bot(); val w = World(b)
        b.albumResponder = { AlbumResult.Failed(TgError.BadRequest("PHOTO_INVALID_DIMENSIONS")) }
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.photo(2, ageMs = 3 * day - 60_000), w.photo(3, ageMs = 3 * day - 120_000))
        val out = w.run()
        assertThat(out.filesDone).isEqualTo(3)
        assertThat(b.jobs.map { it.displayName }).containsExactly("IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg").inOrder()
        assertThat(w.all().all { it.state == FileState.VERIFIED }).isTrue()
    }

    @Test fun networkTroubleOnAnAlbumLeavesEveryFileQueuedWithoutAttempts() {
        val b = bot(); val w = World(b)
        b.albumResponder = { AlbumResult.Failed(TgError.Network) }
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.photo(2, ageMs = 3 * day - 60_000), w.photo(3, ageMs = 3 * day - 120_000))
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.NO_INTERNET)
        assertThat(w.all().all { it.state == FileState.QUEUED && it.attempts == 0 }).isTrue()
        assertThat(b.jobs).isEmpty()
    }

    @Test fun aSlowDownAnswerBlamesOnlyTheFirstFileThenTheAlbumGoesThrough() {
        val b = bot(); val w = World(b)
        var first = true
        b.albumResponder = { if (first) { first = false; AlbumResult.Failed(TgError.FloodWait(5)) } else null }
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.photo(2, ageMs = 3 * day - 60_000), w.photo(3, ageMs = 3 * day - 120_000))
        val out = w.run()
        assertThat(out.filesDone).isEqualTo(3)
        assertThat(w.all().all { it.state == FileState.VERIFIED }).isTrue()
        assertThat(w.all().count { it.attempts > 0 }).isAtMost(1)
    }

    @Test fun aDeadTokenOnAnAlbumStopsTheBotAndKeepsEveryFile() {
        val b = bot(); val w = World(b)
        b.albumResponder = { AlbumResult.Failed(TgError.BadToken) }
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.photo(2, ageMs = 3 * day - 60_000))
        w.run()
        assertThat(w.settings.botProblem).isTrue()
        assertThat(w.all().none { it.state == FileState.VERIFIED || it.state == FileState.SKIPPED }).isTrue()
        assertThat(b.jobs).isEmpty()
    }

    @Test fun anAnswerWithTheWrongNumberOfMessagesIsNotTrusted() {
        val b = bot(); val w = World(b)
        b.albumResponder = { jobs -> AlbumResult.Sent(listOf(SentMessage(jobs[0].chatId, jobs[0].threadId, 1, "u", jobs[0].sizeBytes, null, null, null, jobs[0].sendAs))) }
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, ageMs = 3 * day), w.photo(2, ageMs = 3 * day - 60_000))
        val out = w.run()
        assertThat(w.all().none { it.state == FileState.VERIFIED }).isTrue()
        assertThat(w.all().all { it.attempts >= 1 }).isTrue()
        assertThat(out.reason).isNotEqualTo(StopReason.OS_STOPPED)
        assertThat(b.albums.size).isAtMost(w.settings.maxAttempts)   // never an endless re-posting
    }
}
