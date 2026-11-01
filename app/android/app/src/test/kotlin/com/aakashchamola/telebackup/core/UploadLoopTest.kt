package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.telegram.*
import com.aakashchamola.telebackup.core.upload.StopReason
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Test

class UploadLoopTest {
    private fun world(bot: FakeSender? = FakeSender.ok(), account: FakeSender? = null) = World(bot, account)

    private fun World.run(stopAfter: Int = Int.MAX_VALUE) = runBlocking {
        var calls = 0
        loop().run { calls++ >= stopAfter }
    }

    @Test fun uploadsEverythingOldestFirstAndVerifies() {
        val w = world()
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE)
        w.scanWith(r, w.photo(1, ageMs = 30 * Fx.DAY), w.photo(2, ageMs = 1 * Fx.DAY), w.photo(3, ageMs = 10 * Fx.DAY))
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.QUEUE_EMPTY)
        assertThat(out.filesDone).isEqualTo(3)
        assertThat((w.bot as FakeSender).jobs.map { it.displayName }).containsExactly("IMG_1.jpg", "IMG_3.jpg", "IMG_2.jpg").inOrder()
        assertThat(w.all().all { it.state == FileState.VERIFIED }).isTrue()
        assertThat(w.all().first().deleteAfter!!).isAtLeast(w.clock.now() + 7 * Fx.DAY)
        assertThat(w.all().first().sha256).isNotNull()
        assertThat((w.bot as FakeSender).jobs.first().caption).contains("#tb abababababab")
        assertThat(w.eventStore.kinds()).containsAtLeast(EventKind.UPLOADED, EventKind.VERIFIED)
        assertThat(w.settings.lastUploadAt).isNotNull()
    }

    @Test fun uploadOnlyRulesNeverGetADeleteDate() {
        val w = world()
        val r = w.rule(mode = RuleMode.UPLOAD_ONLY)
        w.scanWith(r, w.photo(1))
        w.run()
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
        assertThat(w.all().single().deleteAfter).isNull()
    }

    @Test fun usesTheRulesTopic() {
        val w = world()
        val r = w.rule(topic = 42)
        w.scanWith(r, w.photo(1))
        w.run()
        assertThat((w.bot as FakeSender).jobs.single().threadId).isEqualTo(42)
        assertThat(w.all().single().tgThreadId).isEqualTo(42)
    }

    @Test fun doesNothingWhenPaused() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.control.pause()
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.PAUSED)
        assertThat(w.all().single().state).isEqualTo(FileState.QUEUED)
    }

    @Test fun pauseDuringAFileLetsItFinishThenHolds() {
        val bot = FakeSender.ok()
        val w = world(bot)
        val r = w.rule(); w.scanWith(r, w.photo(1, ageMs = 5 * Fx.DAY), w.photo(2, ageMs = 6 * Fx.DAY), w.photo(3, ageMs = 7 * Fx.DAY))
        val inner = bot.responder
        bot.responder = { j -> if (bot.jobs.size == 1) w.control.pause(); inner(j) }
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.PAUSED)
        assertThat(w.all().count { it.state == FileState.VERIFIED }).isEqualTo(1)
        assertThat(w.all().count { it.state == FileState.QUEUED }).isEqualTo(2)
    }

    @Test fun delayHoldsUntilItsTimeThenRuns() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.control.delay(120)
        assertThat(w.run().reason).isEqualTo(StopReason.PAUSED)
        w.clock.advance(121 * 60_000)
        assertThat(w.run().filesDone).isEqualTo(1)
    }

    @Test fun osStopReturnsTheFileToTheQueueWithoutCountingAnAttempt() {
        val bot = FakeSender { throw CancellationException("stopped") }
        val w = world(bot)
        val r = w.rule(); w.scanWith(r, w.photo(1))
        try { w.run() } catch (_: CancellationException) {}
        val f = w.all().single()
        assertThat(f.state).isEqualTo(FileState.QUEUED)
        assertThat(f.attempts).isEqualTo(0)
    }

    @Test fun stoppedFlagEndsTheRunBetweenFiles() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1), w.photo(2), w.photo(3))
        val out = w.run(stopAfter = 2)
        assertThat(out.reason).isEqualTo(StopReason.OS_STOPPED)
        assertThat(w.all().count { it.state == FileState.QUEUED }).isAtLeast(1)
    }

    @Test fun threeNetworkFailuresInARowStopTheRunWithoutAttempts() {
        val bot = FakeSender { SendResult.Failed(TgError.Network) }
        val w = world(bot)
        val r = w.rule(); w.scanWith(r, w.photo(1), w.photo(2), w.photo(3), w.photo(4))
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.NO_INTERNET)
        assertThat(w.all().all { it.attempts == 0 && it.state == FileState.QUEUED }).isTrue()
    }

    @Test fun accountFilesWaitButBotFilesContinue() {
        val w = world(FakeSender.ok(), account = null)
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1), w.video(2))
        val out = w.run()
        assertThat(out.reason).isEqualTo(StopReason.NOTHING_TO_SEND)
        assertThat(w.all().first { it.displayName == "IMG_1.jpg" }.state).isEqualTo(FileState.VERIFIED)
        assertThat(w.all().first { it.displayName == "VID_2.mp4" }.state).isEqualTo(FileState.QUEUED)
    }

    @Test fun accountFilesGoThroughTheAccountWhenReady() {
        val acct = FakeSender.ok()
        val w = world(FakeSender.ok(), account = acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1), w.video(2))
        w.run()
        assertThat(acct.jobs.map { it.displayName }).containsExactly("VID_2.mp4")
        assertThat(w.all().all { it.state == FileState.VERIFIED }).isTrue()
    }

    @Test fun floodWaitIsObeyedThenTheFileIsRetriedWithoutAnAttempt() {
        var first = true
        val inner = FakeSender.ok()
        val bot = FakeSender { j -> if (first) { first = false; SendResult.Failed(TgError.FloodWait(30)) } else inner.responder(j) }
        val w = world(bot)
        val r = w.rule(); w.scanWith(r, w.photo(1))
        val t0 = w.clock.now()
        val out = w.run()
        assertThat(out.filesDone).isEqualTo(1)
        assertThat(w.clock.now() - t0).isAtLeast(31_000)
        assertThat(w.all().single().attempts).isEqualTo(0)
    }

    @Test fun missingTopicPausesOnlyThatRule() {
        val bot = FakeSender { j ->
            if (j.threadId == 7L) SendResult.Failed(TgError.TopicMissing)
            else SendResult.Sent(SentMessage(j.chatId, j.threadId, 500, "u", j.sizeBytes, null, null, null, j.sendAs))
        }
        val w = world(bot)
        w.topics.upsert(com.aakashchamola.telebackup.core.db.TopicEntity(7, -1001, "Gone"))
        val bad = w.rule(name = "Bad", topic = 7); val good = w.rule(name = "Good", topic = 8)
        w.media.add(w.photo(1)); w.media.add(w.photo(2, folder = "Pictures/teleBackupTest/"))
        w.scanner.scan(bad); w.scanner.scan(good); w.syncDisk()
        // both rules watch the same folder, so each file exists once per rule
        w.run()
        assertThat(w.all().filter { it.ruleId == bad.id }.all { it.state == FileState.QUEUED }).isTrue()
        assertThat(w.all().filter { it.ruleId == good.id }.all { it.state == FileState.VERIFIED }).isTrue()
        assertThat(w.topics.get(7)!!.missing).isTrue()
        assertThat(w.eventStore.kinds()).contains(EventKind.TOPIC_MISSING)
    }

    @Test fun badTokenStopsTheBotRouteOnly() {
        val bot = FakeSender { SendResult.Failed(TgError.BadToken) }
        val acct = FakeSender.ok()
        val w = world(bot, acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1), w.photo(2), w.video(3))
        w.run()
        assertThat(w.all().first { it.displayName == "VID_3.mp4" }.state).isEqualTo(FileState.VERIFIED)
        assertThat(w.all().filter { it.route == Route.BOT }.all { it.state == FileState.QUEUED }).isTrue()
        assertThat(bot.jobs).hasSize(1)
        assertThat(w.eventStore.kinds()).contains(EventKind.BOT_PROBLEM)
    }

    @Test fun accountLoggedOutMarksTheAccountExpired() {
        val acct = FakeSender { SendResult.Failed(TgError.AccountLoggedOut) }
        val w = world(FakeSender.ok(), acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.video(1))
        w.run()
        assertThat(w.settings.accountState).isEqualTo(AccountValue.EXPIRED)
        assertThat(w.all().single().state).isEqualTo(FileState.QUEUED)
    }

    @Test fun replyThatDoesNotMatchIsNotVerified() {
        val bot = FakeSender { j -> SendResult.Sent(SentMessage(j.chatId, j.threadId, 9, "u", j.sizeBytes - 1, null, null, null, j.sendAs)) }
        val w = world(bot)
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE); w.scanWith(r, w.photo(1))
        w.run()
        val f = w.all().single()
        assertThat(f.state).isEqualTo(FileState.FAILED)
        assertThat(f.attempts).isEqualTo(1)
        assertThat(f.deleteAfter).isNull()
        assertThat(w.eventStore.kinds()).contains(EventKind.VERIFY_FAILED)
    }

    @Test fun repeatedBadRequestsEndInSkipped() {
        val bot = FakeSender { SendResult.Failed(TgError.BadRequest("wrong file type")) }
        val w = world(bot)
        val r = w.rule(); w.scanWith(r, w.photo(1))
        repeat(8) { w.run(); w.clock.advance(7 * 3_600_000L) }
        val f = w.all().single()
        assertThat(f.state).isEqualTo(FileState.SKIPPED)
        assertThat(f.attempts).isEqualTo(5)
        assertThat(w.eventStore.kinds()).contains(EventKind.SKIPPED)
    }

    @Test fun tooLargeMovesToTheAccount() {
        val bot = FakeSender { SendResult.Failed(TgError.TooLarge) }
        val acct = FakeSender.ok()
        val w = world(bot, acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.run()
        assertThat(acct.jobs).hasSize(1)
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
    }

    @Test fun fileGoneFromDiskBecomesGone() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.disk.facts.clear()
        w.run()
        assertThat(w.all().single().state).isEqualTo(FileState.GONE)
        assertThat((w.bot as FakeSender).jobs).isEmpty()
    }

    @Test fun fileEditedSinceTheScanIsRefreshedAndThenUploaded() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1, size = 1000))
        val f = w.all().single()
        w.disk.facts[f.path] = DiskFacts(true, 5000, f.modifiedAt + 1000)
        w.run()
        val after = w.all().single()
        assertThat(after.sizeBytes).isEqualTo(5000)            // the row was refreshed to the file as it is now
        assertThat(after.state).isEqualTo(FileState.VERIFIED)  // and the new version was uploaded in the same run
        assertThat((w.bot as FakeSender).jobs.single().sizeBytes).isEqualTo(5000)
    }

    @Test fun chatMigrationIsFollowed() {
        var first = true
        val inner = FakeSender.ok()
        val bot = FakeSender { j -> if (first) { first = false; SendResult.Failed(TgError.ChatMigrated(-1009L)) } else inner.responder(j) }
        val w = world(bot)
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.run()
        assertThat(w.settings.chatId).isEqualTo(-1009L)
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
        assertThat(w.all().single().tgChatId).isEqualTo(-1009L)
    }

    @Test fun crashRecoveryFinishesAFileTelegramAlreadyHad() {
        val w = world()
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE); w.scanWith(r, w.photo(1))
        val f = w.all().single()
        w.files.rows[f.id] = f.copy(state = FileState.UPLOADING, tgMessageId = 55, tgChatId = -1001, tgThreadId = 5,
            tgSize = f.sizeBytes, sendAs = SendAs.DOCUMENT)
        val out = w.run()
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
        assertThat((w.bot as FakeSender).jobs).isEmpty()
        assertThat(out.filesDone).isEqualTo(0)
    }

    @Test fun crashRecoveryRequeuesAFileTelegramNeverAnswered() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1))
        val f = w.all().single()
        w.files.rows[f.id] = f.copy(state = FileState.UPLOADING)
        w.run()
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
        assertThat((w.bot as FakeSender).jobs).hasSize(1)
    }

    @Test fun notSetUpWithoutAGroup() {
        val w = world()
        w.kv.put("telegram.chatId", null)
        val r = w.rule(); w.scanWith(r, w.photo(1))
        assertThat(w.run().reason).isEqualTo(StopReason.NOT_SET_UP)
    }

    @Test fun disabledRuleFilesAreNotSent() {
        val w = world()
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.repo.setEnabled(r.id, false)
        w.run()
        assertThat(w.all().single().state).isEqualTo(FileState.QUEUED)
        assertThat((w.bot as FakeSender).jobs).isEmpty()
    }

    @Test fun mobileOnceFlagClearsWhenTheQueueEmpties() {
        val w = world()
        w.settings.mobileOnceUntilEmpty = true
        val r = w.rule(); w.scanWith(r, w.photo(1))
        w.run()
        assertThat(w.settings.mobileOnceUntilEmpty).isFalse()
    }
}
