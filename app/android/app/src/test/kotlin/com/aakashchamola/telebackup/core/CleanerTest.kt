package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.*
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Test

class CleanerTest {
    /** A delete rule with [n] files already backed up and past their retention date. */
    private fun due(n: Int, dryRun: Boolean = true, mode: RuleMode = RuleMode.UPLOAD_AND_DELETE): World {
        val w = World(FakeSender.ok())
        w.settings.accountState = AccountValue.READY
        val r = w.rule(mode = mode, dryRun = dryRun, days = 7)
        repeat(n) { w.media.add(w.photo(it + 1, ageMs = (20 + it) * Fx.DAY)) }
        w.scanner.scan(r); w.syncDisk()
        runBlocking { w.loop().run { false } }
        w.clock.advance(8 * Fx.DAY)
        return w
    }

    private fun World.clean(access: Boolean = true, review: Long? = null) = runBlocking { cleaner().run(access, review) }

    @Test fun dryRunMakesAReviewAndDeletesNothing() {
        val w = due(3)
        val out = w.clean()
        assertThat(out.reviewsCreated).isEqualTo(1)
        assertThat(out.deleted).isEqualTo(0)
        assertThat(w.deleter.deleted).isEmpty()
        assertThat(w.reviews.rows.values.single().fileCount).isEqualTo(3)
        assertThat(w.all().all { it.state == FileState.VERIFIED && it.reviewId != null }).isTrue()
        // a second run does not make another review
        assertThat(w.clean().reviewsCreated).isEqualTo(0)
        assertThat(w.reviews.rows).hasSize(1)
    }

    @Test fun approvedReviewDeletesExactlyTheReviewedFiles() {
        val w = due(3)
        w.clean()
        // a fourth file is verified later and is not in the review
        val reviewId = w.reviews.rows.keys.single()
        val extra = Fx.file(id = 99, state = FileState.VERIFIED).copy(ruleId = 1, path = "/storage/emulated/0/Pictures/teleBackupTest/extra.jpg",
            deleteAfter = w.clock.now() - 1, route = Route.BOT)
        w.files.rows[99] = extra; w.disk.sync(extra)
        w.reviewsApi.approve(reviewId)
        val out = w.clean(review = reviewId)
        assertThat(out.deleted).isEqualTo(3)
        assertThat(w.deleter.deleted.map { it.id }).doesNotContain(99L)
        assertThat(w.files.get(99)!!.state).isEqualTo(FileState.VERIFIED)
        assertThat(w.rules.get(1)!!.dryRun).isFalse()
        assertThat(w.all().filter { it.id != 99L }.all { it.state == FileState.DELETED }).isTrue()
        assertThat(out.freedBytes).isEqualTo(6_000_000)
    }

    @Test fun afterApprovalLaterBatchesDeleteByThemselves() {
        val w = due(2)
        w.clean()
        w.reviewsApi.approve(w.reviews.rows.keys.single())
        w.clean(review = 1)
        val late = Fx.file(id = 50, state = FileState.VERIFIED).copy(ruleId = 1, path = "/storage/emulated/0/Pictures/teleBackupTest/late.jpg",
            deleteAfter = w.clock.now() - 1, route = Route.BOT)
        w.files.rows[50] = late; w.disk.sync(late)
        val out = w.clean()
        assertThat(out.deleted).isEqualTo(1)
    }

    @Test fun notDueIsNotDeleted() {
        val w = due(2, dryRun = false)
        w.clock.advance(-8 * Fx.DAY)
        assertThat(w.clean().deleted).isEqualTo(0)
        assertThat(w.deleter.deleted).isEmpty()
    }

    @Test fun uploadOnlyRuleNeverDeletes() {
        val w = due(2, dryRun = false, mode = RuleMode.UPLOAD_ONLY)
        val out = w.clean()
        assertThat(out.deleted).isEqualTo(0)
        assertThat(w.deleter.deleted).isEmpty()
    }

    @Test fun fileChangedOnDiskIsNotDeletedAndBecomesChanged() {
        val w = due(1, dryRun = false)
        val f = w.all().single()
        w.disk.facts[f.path] = DiskFacts(true, f.sizeBytes + 10, f.modifiedAt)
        w.clean()
        assertThat(w.deleter.deleted).isEmpty()
        assertThat(w.all().single().state).isEqualTo(FileState.CHANGED)
    }

    @Test fun fileGoneFromDiskBecomesGone() {
        val w = due(1, dryRun = false)
        w.disk.facts.clear()
        w.clean()
        assertThat(w.all().single().state).isEqualTo(FileState.GONE)
    }

    @Test fun messageDeletedInTelegramIsRequeuedNotDeleted() {
        val w = due(1, dryRun = false)
        w.verifier.answer = AccountCheck.NOT_FOUND
        w.clean()
        assertThat(w.deleter.deleted).isEmpty()
        val f = w.all().single()
        assertThat(f.state).isEqualTo(FileState.QUEUED)
        assertThat(f.tgMessageId).isNull()
    }

    @Test fun strongCheckUnavailableWaits() {
        val w = due(1, dryRun = false)
        w.verifier.answer = AccountCheck.UNAVAILABLE
        w.clean()
        assertThat(w.deleter.deleted).isEmpty()
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
        assertThat(w.eventStore.kinds()).contains(EventKind.DELETE_DENIED)
    }

    @Test fun botOnlySetupDoesNotDeleteUntilTheOwnerAllowsIt() {
        val w = due(1, dryRun = false)
        w.settings.accountState = AccountValue.NONE
        assertThat(w.clean().deleted).isEqualTo(0)
        w.settings.allowBotOnlyDelete = true
        assertThat(w.clean().deleted).isEqualTo(1)
    }

    @Test fun deniedReasonIsLoggedOncePerFile() {
        val w = due(1, dryRun = false)
        w.verifier.answer = AccountCheck.UNAVAILABLE
        repeat(3) { w.clean() }
        assertThat(w.eventStore.rows.count { it.kind == EventKind.DELETE_DENIED }).isEqualTo(1)
    }

    @Test fun lostPermissionBlocksEveryDeleteAndLiftsByItself() {
        val w = due(2, dryRun = false)
        val out = w.clean(access = false)
        assertThat(out.blockedReason).isEqualTo("PERMISSION_LOST")
        assertThat(w.deleter.deleted).isEmpty()
        assertThat(w.eventStore.kinds()).contains(EventKind.PERMISSION_LOST)
        assertThat(w.clean(access = true).deleted).isEqualTo(2)
        assertThat(w.settings.deletesBlockedReason).isNull()
        assertThat(w.eventStore.kinds()).contains(EventKind.PERMISSION_BACK)
    }

    @Test fun capsAtFiveHundredPerRulePerRun() {
        val w = World(FakeSender.ok())
        w.settings.accountState = AccountValue.READY
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE, dryRun = false)
        repeat(600) {
            val f = Fx.file(id = it + 1L, state = FileState.VERIFIED).copy(ruleId = r.id, route = Route.BOT, takenAt = it.toLong(),
                path = "/storage/emulated/0/Pictures/teleBackupTest/f$it.jpg", deleteAfter = w.clock.now() - 1)
            w.files.rows[f.id] = f; w.disk.sync(f)
        }
        assertThat(w.clean().deleted).isEqualTo(500)
        assertThat(w.clean().deleted).isEqualTo(100)
    }

    @Test fun deleterFailureLeavesTheFileAlone() {
        val w = due(1, dryRun = false)
        w.deleter.fail = "refused"
        w.clean()
        assertThat(w.all().single().state).isEqualTo(FileState.VERIFIED)
    }

    @Test fun disabledRuleDeletesNothing() {
        val w = due(2, dryRun = false)
        w.repo.setEnabled(1, false)
        assertThat(w.clean().deleted).isEqualTo(0)
    }

    @Test fun dismissedReviewReleasesTheFiles() {
        val w = due(2)
        w.clean()
        w.reviewsApi.dismiss(w.reviews.rows.keys.single())
        assertThat(w.all().all { it.reviewId == null }).isTrue()
        assertThat(w.deleter.deleted).isEmpty()
    }

    @Test fun killSwitchTurnsEveryRuleToUploadOnlyAndClearsDeleteDates() {
        val w = due(2)
        w.clean()
        w.kill.stopAllDeletes()
        val r = w.rules.get(1)!!
        assertThat(r.mode).isEqualTo(RuleMode.UPLOAD_ONLY)
        assertThat(r.deleteWarningAcceptedAt).isNull()
        assertThat(w.all().all { it.deleteAfter == null && it.reviewId == null }).isTrue()
        assertThat(w.reviews.rows.values.single().status).isEqualTo(ReviewStatus.DISMISSED)
        assertThat(w.clean().deleted).isEqualTo(0)
        assertThat(w.deleter.deleted).isEmpty()
        assertThat(w.eventStore.kinds()).contains(EventKind.KILL_SWITCH)
    }

    /** Tries every route to delete an unverified file; none may work. */
    @Test fun noRouteDeletesAFileThatIsNotVerified() {
        for (state in FileState.values().filter { it != FileState.VERIFIED }) {
            val w = World(FakeSender.ok())
            val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE, dryRun = false)
            val f = Fx.file(id = 1, state = state).copy(ruleId = r.id, deleteAfter = w.clock.now() - 1, tgMessageId = 5, tgChatId = -1001,
                reviewId = null)
            w.files.rows[1] = f; w.disk.sync(f)
            w.settings.accountState = AccountValue.READY
            w.clean()
            assertThat(w.deleter.deleted).isEmpty()
            if (state != FileState.DELETED) assertThat(w.files.get(1)!!.state).isNotEqualTo(FileState.DELETED)
        }
    }
}
