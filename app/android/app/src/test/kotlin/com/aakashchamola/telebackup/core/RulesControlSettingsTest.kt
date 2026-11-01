package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.control.ControlState
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.RuleException
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test

class ControlStateTest {
    private val w = World()

    @Test fun pauseDelayResume() {
        w.control.pause()
        assertThat(w.settings.controlState).isEqualTo(ControlValue.PAUSED)
        w.control.delay(120)
        assertThat(w.settings.controlState).isEqualTo(ControlValue.DELAYED)
        assertThat(w.settings.delayedUntil).isEqualTo(w.clock.now() + 120 * 60_000L)
        assertThat(w.scheduler.calls).contains("resumeAt:${120 * 60_000L}")
        w.control.resume()
        assertThat(w.settings.controlState).isEqualTo(ControlValue.RUNNING)
        assertThat(w.settings.delayedUntil).isNull()
        assertThat(w.scheduler.calls).containsAtLeast("cancelResumeAt", "upload")
        assertThat(w.eventStore.kinds()).containsAtLeast(EventKind.PAUSED, EventKind.DELAYED, EventKind.RESUMED)
    }

    @Test fun delayTimerResumesOnlyWhileStillDelayed() {
        w.control.delay(120)
        w.clock.advance(121 * 60_000L)
        w.control.onResumeAtFired()
        assertThat(w.settings.controlState).isEqualTo(ControlValue.RUNNING)
        w.control.pause()
        w.control.onResumeAtFired()
        assertThat(w.settings.controlState).isEqualTo(ControlValue.PAUSED)
    }

    @Test fun delayBoundsAndDescription() {
        assertThrows(IllegalArgumentException::class.java) { w.control.delay(5) }
        assertThrows(IllegalArgumentException::class.java) { w.control.delay(2000) }
        assertThat(ControlState.describe(120)).isEqualTo("2 hours")
        assertThat(ControlState.describe(60)).isEqualTo("1 hour")
        assertThat(ControlState.describe(45)).isEqualTo("45 minutes")
    }
}

class SettingsRepositoryTest {
    private val kv = MemKv()
    private val s = SettingsRepository(kv)

    @Test fun defaults() {
        assertThat(s.allowMobileData).isFalse()
        assertThat(s.controlState).isEqualTo(ControlValue.RUNNING)
        assertThat(s.delayOptionsMinutes).containsExactly(120, 300).inOrder()
        assertThat(s.defaultRetentionDays).isEqualTo(7)
        assertThat(s.botPacePerMinute).isEqualTo(15)
        assertThat(s.botMaxBytes).isEqualTo(52_428_800L)
        assertThat(s.accountState).isEqualTo(AccountValue.NONE)
        assertThat(s.setupStep).isEqualTo("O1")
        assertThat(s.setupDone).isFalse()
        assertThat(s.allowBotOnlyDelete).isFalse()
    }

    @Test fun delayOptionsBounds() {
        s.delayOptionsMinutes = listOf(30, 60, 180)
        assertThat(s.delayOptionsMinutes).containsExactly(30, 60, 180).inOrder()
        assertThrows(IllegalArgumentException::class.java) { s.delayOptionsMinutes = emptyList() }
        assertThrows(IllegalArgumentException::class.java) { s.delayOptionsMinutes = listOf(15, 30, 45, 60, 90) }
        assertThrows(IllegalArgumentException::class.java) { s.delayOptionsMinutes = listOf(10) }
        assertThrows(IllegalArgumentException::class.java) { s.delayOptionsMinutes = listOf(1500) }
    }

    @Test fun corruptStoredValuesFallBackToDefaults() {
        kv.put(SettingsRepository.Keys.DELAY_OPTIONS, "abc,1")
        kv.put(SettingsRepository.Keys.CONTROL_STATE, "NONSENSE")
        assertThat(s.delayOptionsMinutes).containsExactly(120, 300).inOrder()
        assertThat(s.controlState).isEqualTo(ControlValue.RUNNING)
    }

    @Test fun retentionBounds() {
        assertThrows(IllegalArgumentException::class.java) { s.defaultRetentionDays = 0 }
        s.defaultRetentionDays = 30
        assertThat(s.defaultRetentionDays).isEqualTo(30)
    }

    @Test fun unknownKeysAreIgnored() {
        kv.put("something.else", "x")
        assertThat(s.allowMobileData).isFalse()
    }
}

class RuleRepositoryTest {
    private val w = World()

    @Test fun validationProblemsComeBackInPlainWords() {
        val e = assertThrows(RuleException::class.java) { w.repo.save(w.rule().copy(id = 0)) }
        assertThat(e.problems.single().field).isEqualTo("name")
        assertThat(e.problems.single().message).isEqualTo("This name is already used.")
    }

    @Test fun deleteModeNeedsTheWarning() {
        val bad = com.aakashchamola.telebackup.core.db.RuleEntity(name = "X", folderPath = "DCIM/", mode = RuleMode.UPLOAD_AND_DELETE)
        val e = assertThrows(RuleException::class.java) { w.repo.save(bad) }
        assertThat(e.problems.map { it.field }).contains("mode")
    }

    @Test fun newRulesStartInDryRun() {
        assertThat(w.rule().dryRun).isTrue()
    }

    @Test fun changingRetentionRecomputesDeleteDates() {
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE, days = 7)
        val v = Fx.file(id = 1, state = FileState.VERIFIED).copy(ruleId = r.id, verifiedAt = w.clock.now(), deleteAfter = w.clock.now() + 7 * Fx.DAY)
        w.files.rows[1] = v
        w.repo.save(r.copy(retentionDays = 30))
        assertThat(w.files.get(1)!!.deleteAfter).isEqualTo(w.clock.now() + 30 * Fx.DAY)
    }

    @Test fun switchingToUploadOnlyClearsDeleteDates() {
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE)
        w.files.rows[1] = Fx.file(id = 1, state = FileState.VERIFIED).copy(ruleId = r.id, verifiedAt = w.clock.now(), deleteAfter = w.clock.now() + Fx.DAY)
        w.repo.save(r.copy(mode = RuleMode.UPLOAD_ONLY))
        assertThat(w.files.get(1)!!.deleteAfter).isNull()
    }

    @Test fun timeWarpCountsMinutes() {
        w.settings.timeWarp = true
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE, days = 2)
        w.files.rows[1] = Fx.file(id = 1, state = FileState.VERIFIED).copy(ruleId = r.id, verifiedAt = w.clock.now())
        w.repo.refreshDeleteAfter(r)
        assertThat(w.files.get(1)!!.deleteAfter).isEqualTo(w.clock.now() + 2 * 60_000L)
    }

    @Test fun movingTheStartLaterIgnoresWaitingFilesBeforeIt() {
        val r = w.rule(start = StartMode.EVERYTHING)
        w.scanWith(r, w.photo(1, ageMs = 30 * Fx.DAY), w.photo(2, ageMs = 2 * Fx.DAY))
        w.repo.save(r.copy(startMode = StartMode.SINCE_DATE, startDate = w.clock.now() - 10 * Fx.DAY))
        assertThat(w.all().first { it.displayName == "IMG_1.jpg" }.state).isEqualTo(FileState.IGNORED)
        assertThat(w.all().first { it.displayName == "IMG_2.jpg" }.state).isEqualTo(FileState.QUEUED)
    }

    @Test fun softDeleteDropsWaitingFilesKeepsUploadedOnesAndFreesTheName() {
        val r = w.rule()
        w.scanWith(r, w.photo(1), w.photo(2))
        val up = w.all().first()
        w.files.rows[up.id] = up.copy(state = FileState.VERIFIED)
        w.repo.softDelete(r.id)
        assertThat(w.files.get(up.id)!!.state).isEqualTo(FileState.VERIFIED)
        assertThat(w.all().first { it.id != up.id }.state).isEqualTo(FileState.IGNORED)
        assertThat(w.repo.active()).isEmpty()
        assertThat(w.rules.get(r.id)!!.deletedAt).isNotNull()
        w.repo.save(w.rule(name = "Test2").copy(id = 0, name = "Test"))   // the name can be used again
    }
}
