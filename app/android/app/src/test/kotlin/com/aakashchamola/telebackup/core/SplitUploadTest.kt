package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.telegram.*
import com.aakashchamola.telebackup.core.upload.SplitResult
import com.aakashchamola.telebackup.core.upload.VideoSplitter
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** A video over 2 GB: cut into parts, the parts sent together as the account, every part checked, never deleted by the app. */
class SplitUploadTest {
    private class FakeSplitter(val parts: Int = 2, val fail: String? = null) : VideoSplitter {
        var calls = 0
        override suspend fun split(source: File, maxPartBytes: Long, outDir: File, onProgress: (Long, Long) -> Unit): SplitResult {
            calls++
            fail?.let { return SplitResult.Failed(it) }
            outDir.mkdirs()
            return SplitResult.Parts((1..parts).map { i -> File(outDir, "part$i-${source.name}").also { it.writeBytes(ByteArray(1000 * i)) } })
        }
    }

    private val day = Fx.DAY
    private fun scratch(): File = Files.createTempDirectory("tbtest").toFile().resolve("cache/split").also { it.mkdirs() }

    private fun World.run(sp: VideoSplitter?, dir: File) = runBlocking { loop(splitter = sp, scratch = dir).run { false } }

    @Test fun aBigVideoGoesUpInPartsAsOneAlbumAndEveryPartIsChecked() {
        val acct = FakeSender.ok().also { it.albumsSupported = true }
        val w = World(FakeSender.ok(), acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA, mode = RuleMode.UPLOAD_AND_DELETE)
        w.scanWith(r, w.video(1, ageMs = 5 * day, size = 2_500_000_000L))
        val sp = FakeSplitter(parts = 2)
        val out = w.run(sp, scratch())
        assertThat(out.filesDone).isEqualTo(1)
        assertThat(sp.calls).isEqualTo(1)
        assertThat(acct.albums).hasSize(1)
        assertThat(acct.albums[0].map { it.displayName }).containsExactly("VID_1 (part 1 of 2).mp4", "VID_1 (part 2 of 2).mp4").inOrder()
        assertThat(acct.albums[0].all { it.sendAs == SendAs.VIDEO && it.threadId == 5L }).isTrue()
        val f = w.all().single()
        assertThat(f.state).isEqualTo(FileState.VERIFIED)
        assertThat(f.partCount).isEqualTo(2)
        assertThat(f.deleteAfter).isNull()   // nothing is ever scheduled for deleting
    }

    @Test fun aFileSentInPartsIsNeverOfferedForDeleting() {
        val acct = FakeSender.ok().also { it.albumsSupported = true }
        val w = World(FakeSender.ok(), acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA, mode = RuleMode.UPLOAD_AND_DELETE, dryRun = false)
        w.scanWith(r, w.video(1, ageMs = 30 * day, size = 2_500_000_000L))
        w.run(FakeSplitter(), scratch())
        w.clock.advance(60 * day)
        val out = runBlocking { w.cleaner().run(true) }
        assertThat(out.deleted).isEqualTo(0)
        assertThat(out.reviewsCreated).isEqualTo(0)
        assertThat(w.deleter.deleted).isEmpty()
    }

    @Test fun ifCuttingFailsNothingIsSentAndTheFileTakesAFailedAttempt() {
        val acct = FakeSender.ok().also { it.albumsSupported = true }
        val w = World(FakeSender.ok(), acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.video(1, ageMs = 5 * day, size = 2_500_000_000L))
        w.run(FakeSplitter(fail = "its format cannot be cut"), scratch())
        assertThat(acct.albums).isEmpty()
        val f = w.all().single()
        assertThat(f.state).isNotEqualTo(FileState.VERIFIED)
        assertThat(f.attempts).isAtLeast(1)
    }

    @Test fun withoutASplitterABigVideoIsNotSentWhole() {
        val acct = FakeSender.ok().also { it.albumsSupported = true }
        val w = World(FakeSender.ok(), acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.MEDIA)
        w.scanWith(r, w.video(1, ageMs = 5 * day, size = 2_500_000_000L))
        w.run(null, scratch())
        assertThat(acct.jobs).isEmpty()
        assertThat(acct.albums).isEmpty()
    }

    @Test fun aWrongPartInTheAnswerIsNotTrusted() {
        val acct = FakeSender.ok().also { it.albumsSupported = true }
        acct.albumResponder = { jobs -> AlbumResult.Sent(jobs.map { j -> SentMessage(j.chatId, j.threadId, 9, "u", j.sizeBytes - 1, null, null, null, j.sendAs) }) }
        val w = World(FakeSender.ok(), acct)
        w.settings.accountState = AccountValue.READY
        val r = w.rule(uploadAs = UploadAs.ORIGINAL)   // sent as documents: size must match exactly
        w.scanWith(r, w.video(1, ageMs = 5 * day, size = 2_500_000_000L))
        w.run(FakeSplitter(), scratch())
        assertThat(w.all().single().state).isNotEqualTo(FileState.VERIFIED)
    }
}
