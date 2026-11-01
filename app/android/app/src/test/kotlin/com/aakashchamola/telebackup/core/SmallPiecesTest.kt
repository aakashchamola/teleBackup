package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.log.Redactor
import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.RuleValidator
import com.aakashchamola.telebackup.core.telegram.TdIds
import com.aakashchamola.telebackup.core.time.Time
import com.aakashchamola.telebackup.core.upload.*
import com.aakashchamola.telebackup.core.verify.ReplyCheck
import com.aakashchamola.telebackup.core.verify.Verifier
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.time.ZoneId

class BackoffTest {
    @Test fun doublesFromTwoMinutesAndCapsAtSixHours() {
        assertThat(Backoff.delayMillis(1)).isEqualTo(2 * Time.MINUTE)
        assertThat(Backoff.delayMillis(2)).isEqualTo(4 * Time.MINUTE)
        assertThat(Backoff.delayMillis(5)).isEqualTo(32 * Time.MINUTE)
        assertThat(Backoff.delayMillis(12)).isEqualTo(6 * Time.HOUR)
        assertThat(Backoff.delayMillis(30)).isEqualTo(6 * Time.HOUR)
    }
    @Test fun jitterStaysWithinTwentyPercent() {
        val base = Backoff.delayMillis(3)
        assertThat(Backoff.delayMillis(3, 1.0)).isEqualTo(base + base / 5)
        assertThat(Backoff.delayMillis(3, 0.5)).isEqualTo(base + base / 10)
        assertThat(Backoff.delayMillis(3, 5.0)).isEqualTo(base + base / 5)
    }
}

class RouterTest {
    private fun d(size: Long, kind: FileKind, up: UploadAs, name: String = "a.jpg", w: Int? = 4000, h: Int? = 3000) =
        Router.decide(size, kind, up, name, w, h)

    @Test fun fiftyMegabyteEdge() {
        val under = d(52_428_799, FileKind.VIDEO, UploadAs.MEDIA, "a.mp4") as RouteDecision.Go
        val over = d(52_428_800, FileKind.VIDEO, UploadAs.MEDIA, "a.mp4") as RouteDecision.Go
        assertThat(under.route).isEqualTo(Route.BOT)
        assertThat(over.route).isEqualTo(Route.ACCOUNT)
    }
    @Test fun originalIsAlwaysDocument() {
        assertThat((d(1000, FileKind.PHOTO, UploadAs.ORIGINAL) as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
        assertThat((d(1000, FileKind.VIDEO, UploadAs.ORIGINAL, "a.mp4") as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
    }
    @Test fun mediaPhotoRules() {
        assertThat((d(2_000_000, FileKind.PHOTO, UploadAs.MEDIA) as RouteDecision.Go).sendAs).isEqualTo(SendAs.PHOTO)
        assertThat((d(11_000_000, FileKind.PHOTO, UploadAs.MEDIA) as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
        assertThat((d(2_000_000, FileKind.PHOTO, UploadAs.MEDIA, "x.HEIC") as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
        assertThat((d(2_000_000, FileKind.PHOTO, UploadAs.MEDIA, "pano.jpg", 12000, 1000) as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
        assertThat((d(2_000_000, FileKind.PHOTO, UploadAs.MEDIA, "thin.jpg", 3000, 100) as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
    }
    @Test fun aVideoOverTwoGigabytesIsCutIntoPartsForTheAccount() {
        val go = d(2_100_000_000, FileKind.VIDEO, UploadAs.MEDIA, "a.mp4") as RouteDecision.Go
        assertThat(go.route).isEqualTo(Route.ACCOUNT)
        assertThat(go.sendAs).isEqualTo(SendAs.VIDEO)
        assertThat(go.parts).isEqualTo(2)
        assertThat((d(2_900_000_000, FileKind.VIDEO, UploadAs.ORIGINAL, "a.MOV") as RouteDecision.Go).sendAs).isEqualTo(SendAs.DOCUMENT)
        assertThat((d(2_900_000_000, FileKind.VIDEO, UploadAs.MEDIA, "a.mp4") as RouteDecision.Go).parts).isEqualTo(2)
    }

    @Test fun otherOverTwoGigabyteFilesAreStillSkipped() {
        assertThat(d(2_100_000_000, FileKind.PHOTO, UploadAs.MEDIA, "a.jpg")).isInstanceOf(RouteDecision.Skip::class.java)
        assertThat(d(2_100_000_000, FileKind.VIDEO, UploadAs.MEDIA, "a.mkv")).isInstanceOf(RouteDecision.Skip::class.java)   // not a format we can cut
        assertThat(d(30_000_000_000, FileKind.VIDEO, UploadAs.MEDIA, "a.mp4")).isInstanceOf(RouteDecision.Skip::class.java)   // more than 10 parts
    }

    @Test fun splitPlanMath() {
        assertThat(SplitPlan.partsNeeded(1_000_000_000)).isEqualTo(1)
        assertThat(SplitPlan.partsNeeded(1_900_000_000)).isEqualTo(1)
        assertThat(SplitPlan.partsNeeded(1_900_000_001)).isEqualTo(2)
        assertThat(SplitPlan.partsNeeded(2_817_722_834)).isEqualTo(2)
        assertThat(SplitPlan.targetPartBytes(2_817_722_834, 2)).isEqualTo(1_408_861_417L)
        assertThat(SplitPlan.partName("VID_1.mp4", 0, 2)).isEqualTo("VID_1 (part 1 of 2).mp4")
        assertThat(SplitPlan.canSplit("x.MP4")).isTrue()
        assertThat(SplitPlan.canSplit("x.mkv")).isFalse()
    }
}

class PacerTest {
    @Test fun burstThenOnePerFourSeconds() {
        val c = FakeClock()
        val p = Pacer(c, botPerMinute = 15, burst = 3)
        repeat(3) { assertThat(p.reserve(Route.BOT)).isEqualTo(0) }
        assertThat(p.reserve(Route.BOT)).isEqualTo(4000)
        assertThat(p.reserve(Route.BOT)).isEqualTo(8000)
    }
    @Test fun neverMoreThanFifteenInARollingMinute() {
        val c = FakeClock()
        val p = Pacer(c, 15, 3)
        val starts = mutableListOf<Long>()
        repeat(60) {
            c.advance(p.reserve(Route.BOT))
            starts += c.now()
        }
        for (i in starts.indices) {
            val inWindow = starts.count { it >= starts[i] && it < starts[i] + 60_000 }
            assertThat(inWindow).isAtMost(15 + 3)
        }
    }
    @Test fun floodWaitBlocksEveryRoute() {
        val c = FakeClock()
        val p = Pacer(c)
        p.blockAll(c.now() + 30_000)
        assertThat(p.reserve(Route.BOT)).isEqualTo(30_000)
        assertThat(p.reserve(Route.ACCOUNT)).isAtLeast(30_000)
    }
    @Test fun accountKeepsAGap() {
        val c = FakeClock()
        val p = Pacer(c, accountMinGapMs = 10_000)
        assertThat(p.reserve(Route.ACCOUNT)).isEqualTo(0)
        assertThat(p.reserve(Route.ACCOUNT)).isEqualTo(10_000)
    }
}

class CaptionBuilderTest {
    private val utc = ZoneId.of("UTC")
    @Test fun threeLines() {
        val c = CaptionBuilder.build("IMG_1.jpg", 1_793_526_600_000L, "Gallery photos", "a1b2c3d4e5f6aabbcc", utc)
        val lines = c.split("\n")
        assertThat(lines).hasSize(3)
        assertThat(lines[0]).isEqualTo("IMG_1.jpg")
        assertThat(lines[1]).endsWith("· Gallery photos")
        assertThat(lines[2]).isEqualTo("#tb a1b2c3d4e5f6")
    }
    @Test fun longUnicodeNameStaysUnder1024AndKeepsTheEnds() {
        val name = "ünïcödé-" + "x".repeat(1200) + "-end.jpg"
        val c = CaptionBuilder.build(name, 0, "Rule", "ffffffffffffffff", utc)
        assertThat(c.length).isAtMost(1024)
        assertThat(c).contains("...")
        assertThat(c.lines()[0]).startsWith("ünïcödé")
        assertThat(c.lines()[0]).endsWith("-end.jpg")
        assertThat(c).contains("#tb ffffffffffff")
    }
    @Test fun markdownCharactersPassThroughUntouched() {
        val c = CaptionBuilder.build("a_b*c[1].jpg", 0, "R", "aa", utc)
        assertThat(c).startsWith("a_b*c[1].jpg\n")
    }
}

class VerifierTest {
    @Test fun documentSize() {
        assertThat(Verifier.checkReply(Fx.job(SendAs.DOCUMENT, 10), Fx.sent(size = 10))).isEqualTo(ReplyCheck.Ok)
        assertThat(Verifier.checkReply(Fx.job(SendAs.DOCUMENT, 10), Fx.sent(size = 9))).isInstanceOf(ReplyCheck.Mismatch::class.java)
    }
    @Test fun wrongChatOrTopic() {
        assertThat(Verifier.checkReply(Fx.job(), Fx.sent(chat = -5))).isInstanceOf(ReplyCheck.Mismatch::class.java)
        assertThat(Verifier.checkReply(Fx.job(), Fx.sent(thread = 6))).isInstanceOf(ReplyCheck.Mismatch::class.java)
        assertThat(Verifier.checkReply(Fx.job(), Fx.sent(id = 0))).isInstanceOf(ReplyCheck.Mismatch::class.java)
    }
    @Test fun videoDurationWithinOneSecondAndRotation() {
        val j = Fx.job(SendAs.VIDEO, 5, 1920, 1080, 60_000)
        assertThat(Verifier.checkReply(j, Fx.sent(size = 5, w = 1920, h = 1080, dur = 60_900, kind = SendAs.VIDEO))).isEqualTo(ReplyCheck.Ok)
        assertThat(Verifier.checkReply(j, Fx.sent(size = 5, w = 1080, h = 1920, dur = 60_000, kind = SendAs.VIDEO))).isEqualTo(ReplyCheck.Ok)
        assertThat(Verifier.checkReply(j, Fx.sent(size = 5, w = 1920, h = 1080, dur = 62_500, kind = SendAs.VIDEO))).isInstanceOf(ReplyCheck.Mismatch::class.java)
        assertThat(Verifier.checkReply(j, Fx.sent(size = 5, w = 640, h = 480, dur = 60_000, kind = SendAs.VIDEO))).isInstanceOf(ReplyCheck.Mismatch::class.java)
    }
    @Test fun photoAspectRatioAndMinimumLongSide() {
        val j = Fx.job(SendAs.PHOTO, 3_000_000, 4000, 3000)
        assertThat(Verifier.checkReply(j, Fx.sent(w = 1280, h = 960, kind = SendAs.PHOTO))).isEqualTo(ReplyCheck.Ok)
        assertThat(Verifier.checkReply(j, Fx.sent(w = 1280, h = 720, kind = SendAs.PHOTO))).isInstanceOf(ReplyCheck.Mismatch::class.java)
        assertThat(Verifier.checkReply(j, Fx.sent(w = 320, h = 240, kind = SendAs.PHOTO))).isInstanceOf(ReplyCheck.Mismatch::class.java)
        val small = Fx.job(SendAs.PHOTO, 100_000, 800, 600)
        assertThat(Verifier.checkReply(small, Fx.sent(w = 800, h = 600, kind = SendAs.PHOTO))).isEqualTo(ReplyCheck.Ok)
    }
}

class TlogRedactionTest {
    private val token = "123456789:AAH-abcdefghijklmnopqrstuvwxyz0123456"
    @Test fun masksTokensHashesPhonesAndCodes() {
        val raw = "POST https://api.telegram.org/bot$token/sendPhoto hash=0123456789abcdef0123456789abcdef " +
            "phone +91 98765 43210 and 98765 43210 login code 12345"
        val out = Redactor.redact(raw)
        assertThat(out).doesNotContain(token)
        assertThat(out).doesNotContain("AAH-")
        assertThat(out).doesNotContain("0123456789abcdef0123456789abcdef")
        assertThat(out).doesNotContain("98765")
        assertThat(out).doesNotContain("12345")
    }
    @Test fun leavesPlainSentencesAlone() {
        assertThat(Redactor.redact("12 of 240 files, 1.2 GB left")).isEqualTo("12 of 240 files, 1.2 GB left")
    }
    @Test fun loggerRedactsBeforeAnySink() {
        val lines = mutableListOf<String>()
        Tlog.sink = { _, l -> lines += l }
        Tlog.i("calling bot$token")
        Tlog.sink = null
        assertThat(lines.single()).doesNotContain(token)
    }
}

class RuleValidatorTest {
    private fun rule(name: String = "Shots", folder: String = "Pictures/x/", mode: RuleMode = RuleMode.UPLOAD_ONLY,
                     warn: Long? = null, days: Int = 7) =
        Fx.rule(mode = mode, warning = warn).copy(name = name, folderPath = folder, retentionDays = days)

    @Test fun validRulePasses() = assertThat(RuleValidator.validate(rule(), emptyList())).isEmpty()
    @Test fun nameRules() {
        assertThat(RuleValidator.validate(rule(name = " "), emptyList()).map { it.field }).contains("name")
        assertThat(RuleValidator.validate(rule(name = "x".repeat(41)), emptyList()).map { it.field }).contains("name")
        assertThat(RuleValidator.validate(rule(name = "shots"), listOf("Shots")).map { it.field }).contains("name")
    }
    @Test fun folderAndRetention() {
        assertThat(RuleValidator.validate(rule(folder = ""), emptyList()).map { it.field }).contains("folder")
        assertThat(RuleValidator.validate(rule(days = 0), emptyList()).map { it.field }).contains("retention")
        assertThat(RuleValidator.validate(rule(days = 366), emptyList()).map { it.field }).contains("retention")
    }
    @Test fun deleteNeedsTheWarning() {
        assertThat(RuleValidator.validate(rule(mode = RuleMode.UPLOAD_AND_DELETE), emptyList()).map { it.field }).contains("mode")
        assertThat(RuleValidator.validate(rule(mode = RuleMode.UPLOAD_AND_DELETE, warn = 5), emptyList())).isEmpty()
    }
    @Test fun folderIsNormalised() {
        assertThat(RuleValidator.normalizeFolder("/DCIM/Camera")).isEqualTo("DCIM/Camera/")
        assertThat(RuleValidator.normalizeFolder("DCIM\\Camera\\")).isEqualTo("DCIM/Camera/")
    }
}

class TdIdsTest {
    @Test fun roundTrip() {
        assertThat(TdIds.toTdlib(77)).isEqualTo(77L * 1048576)
        assertThat(TdIds.fromTdlib(TdIds.toTdlib(123456))).isEqualTo(123456)
    }
}
