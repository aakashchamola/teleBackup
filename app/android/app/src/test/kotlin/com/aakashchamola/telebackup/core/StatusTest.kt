package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.db.ReviewEntity
import com.aakashchamola.telebackup.core.db.TopicEntity
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.status.*
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.time.ZoneId

class StatusTest {
    private val w = World()
    private var perms = PermissionState(true, true, true, true)
    private var unmetered = true
    private val probe = object : PermissionProbe { override fun state() = perms }
    private val net = object : NetworkProbe { override fun onUnmetered() = unmetered; override fun online() = true }
    private val tracker = RunTracker()
    private fun builder() = StatusBuilder(w.settings, w.files, w.rules, w.topics, w.reviews, tracker, probe, net, w.clock, ZoneId.of("UTC"))
    private fun kinds() = builder().attention().map { it.kind }

    init { w.settings.setupDoneAt = 1 }

    @Test fun healthyPhoneHasNoWarnings() = assertThat(kinds()).isEmpty()

    @Test fun setupNotDone() {
        w.kv.put("app.setupDoneAt", null)
        assertThat(kinds()).contains(AttentionKind.SETUP_NOT_DONE)
    }

    @Test fun lostFilesAccessIsFirstAfterSetup() {
        perms = perms.copy(allFiles = false, notifications = false, batteryExempt = false)
        assertThat(kinds()).containsAtLeast(AttentionKind.ALL_FILES_LOST, AttentionKind.NOTIFICATIONS_OFF, AttentionKind.BATTERY_OPTIMIZED).inOrder()
        assertThat(kinds().first()).isEqualTo(AttentionKind.ALL_FILES_LOST)
    }

    @Test fun expiredLoginAndBigVideosWaiting() {
        w.settings.accountState = AccountValue.EXPIRED
        assertThat(kinds()).contains(AttentionKind.LOGIN_EXPIRED)
        w.settings.accountState = AccountValue.NONE
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.video(1), w.video(2))
        val a = builder().attention().first { it.kind == AttentionKind.BIG_FILES_WAIT_ACCOUNT }
        assertThat(a.count).isEqualTo(2)
        assertThat(a.text).isEqualTo("2 big videos wait for your Telegram account.")
        w.settings.accountState = AccountValue.READY
        assertThat(kinds()).doesNotContain(AttentionKind.BIG_FILES_WAIT_ACCOUNT)
    }

    @Test fun missingTopicAndWaitingReview() {
        val r = w.rule(topic = 9)
        w.topics.upsert(TopicEntity(9, -1001, "Shots", missing = true))
        w.reviews.insert(ReviewEntity(ruleId = r.id, createdAt = 1, fileCount = 42, totalBytes = 1000))
        val list = builder().attention()
        assertThat(list.first { it.kind == AttentionKind.TOPIC_MISSING }.ruleId).isEqualTo(r.id)
        assertThat(list.first { it.kind == AttentionKind.REVIEW_WAITING }.text).contains("42 files ready to delete")
    }

    @Test fun botProblemShowsUntilTheBotWorksAgain() {
        w.settings.botProblem = true
        assertThat(kinds()).contains(AttentionKind.BOT_PROBLEM)
        w.settings.botProblem = false
        assertThat(kinds()).doesNotContain(AttentionKind.BOT_PROBLEM)
    }

    @Test fun skippedThisWeek() {
        val r = w.rule()
        w.files.rows[1] = Fx.file(id = 1, state = FileState.SKIPPED).copy(ruleId = r.id, updatedAt = w.clock.now())
        assertThat(builder().attention().first { it.kind == AttentionKind.SKIPPED_RECENTLY }.count).isEqualTo(1)
    }

    @Test fun snapshotCountsTheQueueAndToday() {
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.photo(1, size = 1000), w.photo(2, size = 3000))
        val s = builder().build()
        assertThat(s.queuedCount).isEqualTo(2)
        assertThat(s.queuedBytes).isEqualTo(4000)
        assertThat(s.run).isEqualTo(RunState.IDLE)
    }

    @Test fun waitingForWifiWhenOnlyMobileAndNotAllowed() {
        val r = w.rule(); w.scanWith(r, w.photo(1))
        unmetered = false
        assertThat(builder().build().run).isEqualTo(RunState.WAITING_NETWORK)
        w.settings.allowMobileData = true
        assertThat(builder().build().run).isEqualTo(RunState.IDLE)
    }

    @Test fun runTrackerShowsUploadingAndPausing() {
        tracker.begin(10); tracker.currentFileName = "a.jpg"; tracker.filesDone = 3
        val s = builder().build()
        assertThat(s.run).isEqualTo(RunState.UPLOADING)
        assertThat(s.runFilesDone).isEqualTo(3); assertThat(s.runFilesTotal).isEqualTo(10)
        tracker.pausing = true
        assertThat(builder().build().run).isEqualTo(RunState.PAUSING)
        tracker.end(timeLimit = true)
        assertThat(builder().build().run).isEqualTo(RunState.STOPPED_TIME_LIMIT)
    }

    @Test fun hubKeepsTheLatest() {
        val hub = StatusHub(builder())
        assertThat(hub.state.value).isNull()
        val s = hub.refresh()
        assertThat(hub.state.value).isEqualTo(s)
    }
}
