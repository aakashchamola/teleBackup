package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.scan.TakenAt
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.time.ZoneId

class ScannerTest {
    private val w = World()

    @Test fun queuesNewestFirstAndDecidesRoute() {
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.media.add(w.photo(1, ageMs = 30 * Fx.DAY)); w.media.add(w.photo(2, ageMs = 1 * Fx.DAY)); w.media.add(w.video(3, ageMs = 5 * Fx.DAY))
        val res = w.scanner.scan(r)
        assertThat(res.newFiles).isEqualTo(3)
        val inInsertOrder = w.all().sortedBy { it.id }
        assertThat(inInsertOrder.map { it.displayName }).containsExactly("IMG_2.jpg", "VID_3.mp4", "IMG_1.jpg").inOrder()
        assertThat(w.all().first { it.displayName == "VID_3.mp4" }.route).isEqualTo(Route.ACCOUNT)
        assertThat(w.all().first { it.displayName == "IMG_1.jpg" }.route).isEqualTo(Route.BOT)
        assertThat(w.all().all { it.state == FileState.QUEUED }).isTrue()
    }

    @Test fun skipsFilesStillBeingWritten() {
        val r = w.rule()
        w.media.add(w.photo(1, ageMs = 60_000)); w.media.add(w.photo(2, ageMs = 3 * 60_000))
        val res = w.scanner.scan(r)
        assertThat(res.newFiles).isEqualTo(1); assertThat(res.tooNew).isEqualTo(1)
    }

    @Test fun todayStartsFromTheMomentTheRuleWasSaved() {
        val r = w.rule(start = StartMode.TODAY)
        assertThat(r.startDate).isEqualTo(w.clock.now())
        w.media.add(w.photo(1, ageMs = 10 * Fx.DAY))
        w.clock.advance(Fx.DAY)
        w.media.add(w.photo(2, ageMs = 10 * 60_000))
        w.clock.advance(Fx.DAY)
        w.scanner.scan(r)
        assertThat(w.all().map { it.displayName }).containsExactly("IMG_2.jpg")
    }

    @Test fun sinceDateAndEverything() {
        val since = w.repo.save(w.rule(name = "A").copy(id = 0, name = "B", startMode = StartMode.SINCE_DATE, startDate = w.clock.now() - 5 * Fx.DAY))
        w.media.add(w.photo(1, ageMs = 10 * Fx.DAY)); w.media.add(w.photo(2, ageMs = 2 * Fx.DAY))
        w.scanner.scan(since)
        assertThat(w.all().map { it.displayName }).containsExactly("IMG_2.jpg")
        val every = w.rules.get(1)!!
        w.scanner.scan(every)
        assertThat(w.all().count { it.ruleId == 1L }).isEqualTo(2)
    }

    @Test fun scanningTwiceDoesNotDuplicate() {
        val r = w.rule()
        w.media.add(w.photo(1)); w.media.add(w.photo(2))
        w.scanner.scan(r); w.scanner.scan(r)
        assertThat(w.all()).hasSize(2)
    }

    @Test fun editedBeforeUploadUpdatesInPlace() {
        val r = w.rule()
        w.media.add(w.photo(1, size = 1000))
        w.scanner.scan(r)
        val id = w.all().single().id
        w.media.remove(w.photo(1).path)
        w.media.add(w.photo(1, size = 2500, ageMs = 5 * Fx.DAY))
        val res = w.scanner.scan(r)
        assertThat(res.updated).isEqualTo(1)
        assertThat(w.all()).hasSize(1)
        assertThat(w.files.get(id)!!.sizeBytes).isEqualTo(2500)
        assertThat(w.files.get(id)!!.state).isEqualTo(FileState.QUEUED)
    }

    @Test fun editedAfterBackupMarksOldChangedAndQueuesTheNewVersion() {
        val r = w.rule(mode = RuleMode.UPLOAD_AND_DELETE)
        w.media.add(w.photo(1, size = 1000))
        w.scanner.scan(r)
        val row = w.all().single()
        w.files.rows[row.id] = Fx.file(id = row.id, state = FileState.VERIFIED).copy(ruleId = r.id, path = row.path, sizeBytes = row.sizeBytes, modifiedAt = row.modifiedAt)
        w.media.remove(row.path)
        w.media.add(w.photo(1, size = 4321, ageMs = 5 * Fx.DAY))
        val res = w.scanner.scan(r)
        assertThat(res.changed).isEqualTo(1)
        assertThat(w.files.get(row.id)!!.state).isEqualTo(FileState.CHANGED)
        assertThat(w.all().filter { it.state == FileState.QUEUED }.single().sizeBytes).isEqualTo(4321)
    }

    @Test fun vanishedFilesBecomeGone() {
        val r = w.rule()
        w.media.add(w.photo(1)); w.media.add(w.photo(2))
        w.scanner.scan(r)
        w.media.remove(w.photo(1).path)
        val res = w.scanner.scan(r)
        assertThat(res.gone).isEqualTo(1)
        assertThat(w.all().first { it.displayName == "IMG_1.jpg" }.state).isEqualTo(FileState.GONE)
    }

    @Test fun subfoldersAndTypeFilter() {
        val noSub = w.rule(sub = false, types = MediaTypes.PHOTOS)
        w.media.add(w.photo(1)); w.media.add(w.photo(2, name = "deep/IMG_2.jpg")); w.media.add(w.video(3))
        w.scanner.scan(noSub)
        assertThat(w.all().map { it.displayName }).containsExactly("IMG_1.jpg")
    }

    @Test fun includeSubfolders() {
        val r = w.rule(sub = true)
        w.media.add(w.photo(1)); w.media.add(w.photo(2, name = "deep/IMG_2.jpg"))
        w.scanner.scan(r)
        assertThat(w.all()).hasSize(2)
    }

    @Test fun hugeBacklogIsInsertedInBatches() {
        val r = w.rule()
        repeat(1300) { w.media.add(w.photo(it + 1, ageMs = (it + 1) * 60_000L + 10 * Fx.DAY)) }
        val res = w.scanner.scan(r)
        assertThat(res.newFiles).isEqualTo(1300)
        assertThat(w.all()).hasSize(1300)
    }

    @Test fun overTwoGigabytesIsSkippedWithAReason() {
        val r = w.rule()
        w.media.add(w.video(1, size = 2_500_000_000L))
        w.scanner.scan(r)
        val f = w.all().single()
        assertThat(f.state).isEqualTo(FileState.SKIPPED)
        assertThat(f.lastError).contains("2 GB")
    }

    @Test fun disabledOrDeletedRulesAreNotScanned() {
        val r = w.rule()
        w.media.add(w.photo(1))
        w.repo.setEnabled(r.id, false)
        assertThat(w.scanner.scan(w.rules.get(r.id)!!).newFiles).isEqualTo(0)
        assertThat(w.all()).isEmpty()
    }

    @Test fun previewCountsWithoutWriting() {
        val r = w.rule()
        w.media.add(w.photo(1, size = 100)); w.media.add(w.photo(2, size = 200))
        val p = w.scanner.preview(r)
        assertThat(p.count).isEqualTo(2); assertThat(p.bytes).isEqualTo(300)
        assertThat(w.all()).isEmpty()
    }

    @Test fun takenAtFromFileNames() {
        val utc = ZoneId.of("UTC")
        fun t(n: String) = TakenAt.fromName(n, utc)
        assertThat(t("IMG-20261101-WA0001.jpg")).isEqualTo(java.time.Instant.parse("2026-11-01T00:00:00Z").toEpochMilli())
        assertThat(t("IMG_20261101_093012.jpg")).isEqualTo(java.time.Instant.parse("2026-11-01T09:30:12Z").toEpochMilli())
        assertThat(t("Screenshot_20261101-093012.png")).isEqualTo(java.time.Instant.parse("2026-11-01T09:30:12Z").toEpochMilli())
        assertThat(t("PXL_20261101_093012345.jpg")).isNotNull()
        assertThat(t("holiday.jpg")).isNull()
        assertThat(t("IMG_20261301_000000.jpg")).isNull()
    }

    @Test fun missingTakenAtFallsBackToNameThenModified() {
        val r = w.rule()
        val named = w.photo(1, name = "IMG-20260101-WA0001.jpg", taken = null)
        w.media.add(named)
        w.scanner.scan(r)
        assertThat(w.all().single().takenAt).isEqualTo(TakenAt.fromName("IMG-20260101-WA0001.jpg", ZoneId.of("UTC")))
    }
}
