package com.aakashchamola.telebackup.core

import androidx.room.Room
import com.aakashchamola.telebackup.core.clean.Cleaner
import com.aakashchamola.telebackup.core.clean.Reviews
import com.aakashchamola.telebackup.core.control.ControlState
import com.aakashchamola.telebackup.core.db.*
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.RuleRepository
import com.aakashchamola.telebackup.core.scan.Scanner
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.upload.Pacer
import com.aakashchamola.telebackup.core.upload.StopReason
import com.aakashchamola.telebackup.core.upload.UploadLoop
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.time.ZoneId

/**
 * The real Room database (SQLite) on the computer through Robolectric, so every SQL query in the DAOs is run
 * for real. The stores must behave exactly like the in-memory fakes the other tests use.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RoomStoresTest {
    private lateinit var db: AppDatabase
    private lateinit var rules: RuleStore
    private lateinit var files: FileStore
    private val now = Fx.NOW

    @Before fun up() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), AppDatabase::class.java).allowMainThreadQueries().build()
        rules = RoomRuleStore(db)
        files = RoomFileStore(db)
    }

    @After fun down() { db.close() }

    private fun rule(name: String = "R", enabled: Boolean = true) = rules.insert(Fx.rule().copy(id = 0, name = name, enabled = enabled))

    private fun file(rule: Long, n: Int, taken: Long = now - n * 1000L, route: Route? = Route.BOT, state: FileState = FileState.QUEUED, size: Long = 100) =
        Fx.file(id = 0, state = FileState.QUEUED, route = route).copy(
            ruleId = rule, path = "/storage/emulated/0/Pictures/x/f$n.jpg", displayName = "f$n.jpg", takenAt = taken, sizeBytes = size, state = state,
            modifiedAt = now - 5 * Fx.DAY,
        )

    // ---------------------------------------------------------------- rules, topics, settings

    @Test fun rulesRoundTripWithEnumsAndSoftDelete() {
        val id = rules.insert(Fx.rule().copy(id = 0, name = "Shots", mediaTypes = MediaTypes.PHOTOS, mode = RuleMode.UPLOAD_AND_DELETE, startMode = StartMode.SINCE_DATE, startDate = 5))
        val got = rules.get(id)!!
        assertThat(got.mediaTypes).isEqualTo(MediaTypes.PHOTOS)
        assertThat(got.mode).isEqualTo(RuleMode.UPLOAD_AND_DELETE)
        assertThat(got.startMode).isEqualTo(StartMode.SINCE_DATE)
        rules.update(got.copy(deletedAt = 9, enabled = false))
        assertThat(rules.active()).isEmpty()
        assertThat(rules.all()).hasSize(1)
    }

    @Test fun topicsAndMissingFlag() {
        val t = db.topicDao()
        t.upsert(TopicEntity(7, -1001, "Shots", createdAt = 1))
        t.upsert(TopicEntity(8, -1001, "Camera", createdAt = 2))
        t.upsert(TopicEntity(9, -555, "Other group", createdAt = 3))
        assertThat(RoomTopicStore(db).list(-1001).map { it.name }).containsExactly("Shots", "Camera").inOrder()
        RoomTopicStore(db).markMissing(7, true)
        assertThat(RoomTopicStore(db).get(7)!!.missing).isTrue()
        RoomTopicStore(db).upsert(TopicEntity(7, -1001, "Shots again"))
        assertThat(RoomTopicStore(db).get(7)!!.name).isEqualTo("Shots again")
    }

    @Test fun settingsStoreAndTypedRepository() {
        val s = SettingsRepository(RoomKeyValueStore(db))
        assertThat(s.allowMobileData).isFalse()
        s.allowMobileData = true
        s.chatId = -1001
        s.delayOptionsMinutes = listOf(30, 90)
        s.accountState = AccountValue.READY
        val again = SettingsRepository(RoomKeyValueStore(db))
        assertThat(again.allowMobileData).isTrue()
        assertThat(again.chatId).isEqualTo(-1001)
        assertThat(again.delayOptionsMinutes).containsExactly(30, 90).inOrder()
        assertThat(again.accountState).isEqualTo(AccountValue.READY)
        again.chatId = null
        assertThat(SettingsRepository(RoomKeyValueStore(db)).chatId).isNull()
    }

    // ---------------------------------------------------------------- the queue query

    @Test fun queueIsOldestFirstAndSkipsWhatItMust() {
        val r = rule()
        files.insertAll(listOf(file(r, 1, taken = 100), file(r, 2, taken = 300), file(r, 3, taken = 200)))
        assertThat(files.nextInQueue(now, true, true, emptySet())!!.displayName).isEqualTo("f1.jpg")
        files.apply(files.nextInQueue(now, true, true, emptySet())!!.id, FileEvent.StartUpload, now)
        assertThat(files.nextInQueue(now, true, true, emptySet())!!.displayName).isEqualTo("f3.jpg")
    }

    @Test fun queueRespectsRoutesRulesAndBackoff() {
        val on = rule("on"); val off = rule("off", enabled = false); val excluded = rule("ex")
        files.insertAll(listOf(
            file(on, 1, taken = 10, route = Route.ACCOUNT), file(on, 2, taken = 20, route = Route.BOT),
            file(off, 3, taken = 99), file(excluded, 4, taken = 98),
        ))
        // bot only: the account file waits, the disabled rule is ignored, the excluded rule is skipped
        assertThat(files.nextInQueue(now, true, false, setOf(excluded))!!.displayName).isEqualTo("f2.jpg")
        files.apply(files.nextInQueue(now, true, false, setOf(excluded))!!.id, FileEvent.StartUpload, now)
        assertThat(files.nextInQueue(now, true, false, setOf(excluded))).isNull()
        assertThat(files.nextInQueue(now, true, true, setOf(excluded))!!.displayName).isEqualTo("f1.jpg")
        assertThat(files.waitingAccountCount()).isEqualTo(1)
        // a file waiting out a flood-wait is hidden until its time
        val f1 = files.nextInQueue(now, true, true, setOf(excluded))!!
        files.updateDetails(f1.copy(nextAttemptAt = now + 60_000))
        assertThat(files.nextInQueue(now, true, true, setOf(excluded))).isNull()
        assertThat(files.nextInQueue(now + 61_000, true, true, setOf(excluded))!!.id).isEqualTo(f1.id)
        assertThat(files.earliestRetryAt()).isEqualTo(now + 60_000)
    }

    @Test fun failedFilesComeBackWhenDue() {
        val r = rule()
        files.insertAll(listOf(file(r, 1)))
        val id = files.nextInQueue(now, true, true, emptySet())!!.id
        files.apply(id, FileEvent.StartUpload, now)
        files.apply(id, FileEvent.TgFailed(com.aakashchamola.telebackup.core.telegram.TgError.BadRequest("x")), now)
        assertThat(files.get(id)!!.state).isEqualTo(FileState.FAILED)
        assertThat(files.nextInQueue(now, true, true, emptySet())).isNull()
        assertThat(files.nextInQueue(now + 3 * 60_000, true, true, emptySet())!!.id).isEqualTo(id)
    }

    @Test fun queueCountsOnlyWhatCanRunNow() {
        val r = rule()
        files.insertAll(listOf(file(r, 1, size = 10), file(r, 2, size = 20, route = Route.ACCOUNT)))
        assertThat(files.queueCount(now, true, false)).isEqualTo(QueueCount(1, 10))
        assertThat(files.queueCount(now, true, true)).isEqualTo(QueueCount(2, 30))
    }

    // ---------------------------------------------------------------- identity, state door, details door

    @Test fun sameFileVersionIsNotInsertedTwice() {
        val r = rule()
        assertThat(files.insertAll(listOf(file(r, 1)))).isEqualTo(1)
        assertThat(files.insertAll(listOf(file(r, 1), file(r, 2)))).isEqualTo(1)
        assertThat(files.find(r, file(r, 1).path, file(r, 1).sizeBytes, file(r, 1).modifiedAt)).isNotNull()
        assertThat(files.findByPath(r, file(r, 2).path)).hasSize(1)
    }

    @Test fun stateChangesOnlyThroughTheMachineAndIllegalMovesAreRefused() {
        val r = rule()
        files.insertAll(listOf(file(r, 1)))
        val id = files.nextInQueue(now, true, true, emptySet())!!.id
        assertThrows(IllegalTransition::class.java) { files.apply(id, FileEvent.ReplyOk(null), now) }
        assertThat(files.get(id)!!.state).isEqualTo(FileState.QUEUED)
        assertThrows(IllegalArgumentException::class.java) { files.updateDetails(files.get(id)!!.copy(state = FileState.VERIFIED)) }
        files.updateDetails(files.get(id)!!.copy(sha256 = "abc"))
        assertThat(files.get(id)!!.sha256).isEqualTo("abc")
        assertThat(files.apply(id, FileEvent.StartUpload, now).state).isEqualTo(FileState.UPLOADING)
        assertThat(files.interrupted().map { it.id }).containsExactly(id)
    }

    // ---------------------------------------------------------------- retention, reviews, counts, paging

    private fun verified(r: Long, n: Int, due: Long, taken: Long = n.toLong()): Long {
        files.insertAll(listOf(file(r, n, taken = taken)))
        val id = files.findByPath(r, file(r, n).path).single().id
        files.apply(id, FileEvent.StartUpload, now)
        files.apply(id, FileEvent.Sent(Fx.sent(chat = -1001, thread = 5, id = 100L + n), "h"), now)
        files.apply(id, FileEvent.ReplyOk(due), now)
        return id
    }

    @Test fun dueFilesOldestFirstWithALimit() {
        val r = rule()
        val a = verified(r, 1, due = now - 10, taken = 300)
        val b = verified(r, 2, due = now - 5, taken = 100)
        verified(r, 3, due = now + 1000, taken = 50)
        assertThat(files.verifiedDue(r, now, 10).map { it.id }).containsExactly(b, a).inOrder()
        assertThat(files.verifiedDue(r, now, 1).map { it.id }).containsExactly(b)
    }

    @Test fun deleteAfterIsRewrittenForVerifiedFilesOnly() {
        val r = rule()
        val v = verified(r, 1, due = now + 5)
        files.insertAll(listOf(file(r, 2)))
        files.setDeleteAfterForRule(r) { it.verifiedAt!! + 777 }
        assertThat(files.get(v)!!.deleteAfter).isEqualTo(now + 777)
        files.setDeleteAfterForRule(r) { null }
        assertThat(files.get(v)!!.deleteAfter).isNull()
    }

    @Test fun reviewMembershipAndLookup() {
        val r = rule()
        val ids = listOf(verified(r, 1, now - 1), verified(r, 2, now - 1))
        val reviews = RoomReviewStore(db)
        val rid = reviews.insert(ReviewEntity(ruleId = r, createdAt = now, fileCount = 2, totalBytes = 200))
        files.setReview(ids, rid)
        assertThat(files.inReview(rid).map { it.id }).containsExactlyElementsIn(ids)
        assertThat(reviews.waitingFor(r)!!.id).isEqualTo(rid)
        assertThat(reviews.allWaiting()).hasSize(1)
        reviews.update(reviews.get(rid)!!.copy(status = ReviewStatus.APPROVED))
        assertThat(reviews.waitingFor(r)).isNull()
        files.setReview(ids, null)
        assertThat(files.inReview(rid)).isEmpty()
    }

    @Test fun countsAndFreedBytes() {
        val r = rule()
        val v = verified(r, 1, now - 1)
        files.insertAll(listOf(file(r, 2, size = 40), file(r, 3, size = 60)))
        val c = files.stateCounts().associate { it.state to it.count }
        assertThat(c[FileState.VERIFIED]).isEqualTo(1)
        assertThat(c[FileState.QUEUED]).isEqualTo(2)
        assertThat(files.uploadedCountSince(now - 1)).isEqualTo(1)
        // delete it through the gate so the permit is real
        val f = files.get(v)!!
        val rl = rules.get(r)!!
        val permit = DeleteGate.check(f, rl.copy(dryRun = false), null, DiskFacts(true, f.sizeBytes, f.modifiedAt), now, true, AccountCheck.OK, false) as GateResult.Allowed
        files.apply(v, FileEvent.DeletedByCleaner(permit, f.sizeBytes), now)
        assertThat(files.freedBytesTotal()).isEqualTo(f.sizeBytes)
        assertThat(files.freedBytesSince(now - 1)).isEqualTo(f.sizeBytes)
        assertThat(files.freedBytesSince(now + 1)).isEqualTo(0)
    }

    @Test fun pagingWalksBackwardsWithACursor() {
        val r = rule()
        files.insertAll((1..7).map { file(r, it) })
        val first = files.page(r, null, null, 3)
        assertThat(first).hasSize(3)
        val second = files.page(r, null, first.last().id, 3)
        assertThat(second.first().id).isLessThan(first.last().id)
        assertThat(files.page(r, FileState.QUEUED, null, 100)).hasSize(7)
        assertThat(files.page(r, FileState.VERIFIED, null, 100)).isEmpty()
        assertThat(files.page(null, null, null, 100)).hasSize(7)
    }

    @Test fun eventsPageFilterSearchAndPrune() {
        val ev = RoomEventStore(db)
        ev.insert(EventEntity(at = 1, kind = EventKind.UPLOADED, ruleId = 1, message = "IMG_1 uploaded"))
        ev.insert(EventEntity(at = 2, kind = EventKind.DELETED, ruleId = 1, message = "IMG_1 deleted"))
        ev.insert(EventEntity(at = 3, kind = EventKind.UPLOADED, ruleId = 2, message = "VID_9 uploaded"))
        assertThat(ev.page(null, null, null, null, 10).map { it.message }).containsExactly("VID_9 uploaded", "IMG_1 deleted", "IMG_1 uploaded").inOrder()
        assertThat(ev.page(setOf(EventKind.UPLOADED), null, null, null, 10)).hasSize(2)
        assertThat(ev.page(null, 2, null, null, 10)).hasSize(1)
        assertThat(ev.page(null, null, "vid", null, 10)).hasSize(1)
        val all = ev.page(null, null, null, null, 10)
        assertThat(ev.page(null, null, null, all[1].id, 10)).hasSize(1)
        assertThat(ev.lastOf(EventKind.DELETED)!!.message).isEqualTo("IMG_1 deleted")
        assertThat(ev.prune(3)).isEqualTo(2)
        assertThat(ev.page(null, null, null, null, 10)).hasSize(1)
    }

    // ---------------------------------------------------------------- the whole pipeline on real SQL

    @Test fun scanUploadReviewAndDeleteOnTheRealDatabase() {
        val clock = FakeClock()
        val settings = SettingsRepository(RoomKeyValueStore(db)).also { it.chatId = -1001; it.accountState = AccountValue.READY }
        val events = EventLog(RoomEventStore(db), clock)
        val topics = RoomTopicStore(db)
        val reviewStore = RoomReviewStore(db)
        val media = FakeMedia()
        val disk = FakeDisk()
        val scheduler = FakeScheduler()
        val repo = RuleRepository(rules, files, settings, events, clock)
        val scanner = Scanner(media, files, settings, events, clock, ZoneId.of("UTC"))
        val bot = FakeSender.ok()
        val loop = UploadLoop(files, rules, topics, events, settings, clock, Pacer(clock, 15, 3, 10_000, sleep = { clock.advance(it) }), FakeHasher(), disk, bot, null)
        val deleter = FakeDeleter()
        val cleaner = Cleaner(rules, files, reviewStore, events, settings, clock, disk, deleter, FakeAccountVerifier(AccountCheck.OK), null)

        val rule = repo.save(RuleEntity(
            name = "Test", folderPath = "Pictures/teleBackupTest/", topicId = 5, uploadAs = UploadAs.ORIGINAL, mode = RuleMode.UPLOAD_AND_DELETE,
            retentionDays = 7, startMode = StartMode.EVERYTHING, deleteWarningAcceptedAt = clock.now(),
        ))
        repeat(5) {
            val p = "/storage/emulated/0/Pictures/teleBackupTest/IMG_$it.jpg"
            media.add(com.aakashchamola.telebackup.core.scan.MediaItem(it + 1L, p, "IMG_$it.jpg", "image/jpeg", 1000L + it, clock.now() - (10 + it) * Fx.DAY,
                clock.now() - (10 + it) * Fx.DAY, 4000, 3000, null, FileKind.PHOTO))
        }
        assertThat(scanner.scan(rule).newFiles).isEqualTo(5)
        files.page(null, null, null, 100).forEach { disk.sync(it) }

        val out = runBlocking { loop.run { false } }
        assertThat(out.reason).isEqualTo(StopReason.QUEUE_EMPTY)
        assertThat(out.filesDone).isEqualTo(5)
        assertThat(files.page(null, null, null, 100).all { it.state == FileState.VERIFIED }).isTrue()
        assertThat(bot.jobs.map { it.displayName }).containsExactly("IMG_4.jpg", "IMG_3.jpg", "IMG_2.jpg", "IMG_1.jpg", "IMG_0.jpg").inOrder()

        // a week later the first delete is a review, not a delete
        clock.advance(8 * Fx.DAY)
        val first = runBlocking { cleaner.run(true) }
        assertThat(first.reviewsCreated).isEqualTo(1)
        assertThat(deleter.deleted).isEmpty()
        val rid = reviewStore.allWaiting().single().id
        Reviews(rules, files, reviewStore, events, clock).approve(rid)
        val second = runBlocking { cleaner.run(true, rid) }
        assertThat(second.deleted).isEqualTo(5)
        assertThat(files.freedBytesTotal()).isEqualTo(1000L + 1001 + 1002 + 1003 + 1004)
        assertThat(files.page(null, null, null, 100).all { it.state == FileState.DELETED }).isTrue()

        // pause survives in the same database
        ControlState(settings, events, clock, scheduler).pause()
        assertThat(SettingsRepository(RoomKeyValueStore(db)).controlState).isEqualTo(ControlValue.PAUSED)
    }
}
