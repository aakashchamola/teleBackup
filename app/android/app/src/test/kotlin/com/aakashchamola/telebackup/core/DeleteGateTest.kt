package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.model.*
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import kotlin.random.Random

class DeleteGateTest {
    private val now = Fx.NOW
    private val file = Fx.file(state = FileState.VERIFIED)
    private val rule = Fx.rule()
    private val disk = DiskFacts(true, file.sizeBytes, file.modifiedAt)

    private fun check(
        f: FileEntity = file, r: RuleEntity = rule, blocked: String? = null, d: DiskFacts = disk,
        n: Long = now, review: Boolean = true, acct: AccountCheck = AccountCheck.OK, botOnly: Boolean = false,
    ) = DeleteGate.check(f, r, blocked, d, n, review, acct, botOnly)

    private fun denied(r: GateResult) = (r as? GateResult.Denied)?.reason

    @Test fun allTrueIsAllowed() {
        assertThat(check()).isInstanceOf(GateResult.Allowed::class.java)
    }

    @Test fun notVerified() {
        for (s in FileState.values().filter { it != FileState.VERIFIED }) {
            assertThat(denied(check(f = file.copy(state = s)))).isEqualTo(DenyReason.NOT_VERIFIED)
        }
        assertThat(denied(check(f = file.copy(tgMessageId = null)))).isEqualTo(DenyReason.NOT_VERIFIED)
        assertThat(denied(check(f = file.copy(tgChatId = null)))).isEqualTo(DenyReason.NOT_VERIFIED)
    }

    @Test fun ruleUploadOnly() =
        assertThat(denied(check(r = rule.copy(mode = RuleMode.UPLOAD_ONLY)))).isEqualTo(DenyReason.RULE_UPLOAD_ONLY)

    @Test fun noWarningAccepted() =
        assertThat(denied(check(r = rule.copy(deleteWarningAcceptedAt = null)))).isEqualTo(DenyReason.NO_WARNING_ACCEPTED)

    @Test fun ruleOffOrDeleted() {
        assertThat(denied(check(r = rule.copy(enabled = false)))).isEqualTo(DenyReason.RULE_OFF)
        assertThat(denied(check(r = rule.copy(deletedAt = 5)))).isEqualTo(DenyReason.RULE_OFF)
    }

    @Test fun deletesBlocked() =
        assertThat(denied(check(blocked = "PERMISSION_LOST"))).isEqualTo(DenyReason.DELETES_BLOCKED)

    @Test fun notDue() {
        assertThat(denied(check(f = file.copy(deleteAfter = now + 1)))).isEqualTo(DenyReason.NOT_DUE)
        assertThat(denied(check(f = file.copy(deleteAfter = null)))).isEqualTo(DenyReason.NOT_DUE)
        assertThat(check(f = file.copy(deleteAfter = now))).isInstanceOf(GateResult.Allowed::class.java)
    }

    @Test fun needsReview() {
        assertThat(denied(check(r = rule.copy(dryRun = true), review = false))).isEqualTo(DenyReason.NEEDS_REVIEW)
        assertThat(check(r = rule.copy(dryRun = true), review = true)).isInstanceOf(GateResult.Allowed::class.java)
    }

    @Test fun fileMissing() =
        assertThat(denied(check(d = disk.copy(exists = false)))).isEqualTo(DenyReason.FILE_MISSING)

    @Test fun fileChanged() {
        assertThat(denied(check(d = disk.copy(sizeBytes = disk.sizeBytes + 1)))).isEqualTo(DenyReason.FILE_CHANGED)
        assertThat(denied(check(d = disk.copy(modifiedAt = disk.modifiedAt + 1)))).isEqualTo(DenyReason.FILE_CHANGED)
    }

    @Test fun telegramMismatch() {
        assertThat(denied(check(acct = AccountCheck.MISMATCH))).isEqualTo(DenyReason.TELEGRAM_MISMATCH)
        assertThat(denied(check(acct = AccountCheck.NOT_FOUND))).isEqualTo(DenyReason.TELEGRAM_MISMATCH)
    }

    @Test fun noStrongCheck() {
        assertThat(denied(check(acct = AccountCheck.UNAVAILABLE, botOnly = true))).isEqualTo(DenyReason.NO_STRONG_CHECK)
        assertThat(denied(check(acct = AccountCheck.NOT_READY, botOnly = false))).isEqualTo(DenyReason.NO_STRONG_CHECK)
    }

    @Test fun botOnlyMayDeleteBotFilesButNeverAccountFiles() {
        assertThat(check(acct = AccountCheck.NOT_READY, botOnly = true)).isInstanceOf(GateResult.Allowed::class.java)
        assertThat(denied(check(f = file.copy(route = Route.ACCOUNT), acct = AccountCheck.NOT_READY, botOnly = true)))
            .isEqualTo(DenyReason.NO_STRONG_CHECK)
    }

    @Test fun everyDenyReasonIsReachable() {
        val seen = mutableSetOf<DenyReason>()
        val cases = listOf(
            check(f = file.copy(state = FileState.QUEUED)), check(r = rule.copy(mode = RuleMode.UPLOAD_ONLY)),
            check(r = rule.copy(deleteWarningAcceptedAt = null)), check(r = rule.copy(enabled = false)),
            check(blocked = "x"), check(f = file.copy(deleteAfter = now + 1)),
            check(r = rule.copy(dryRun = true), review = false), check(d = disk.copy(exists = false)),
            check(d = disk.copy(sizeBytes = 1)), check(acct = AccountCheck.MISMATCH), check(acct = AccountCheck.UNAVAILABLE),
        )
        cases.forEach { denied(it)?.let(seen::add) }
        assertThat(seen).containsExactlyElementsIn(DenyReason.values().toList())
    }

    /** Whatever the inputs, Allowed means every one of the nine conditions really holds. */
    @Test fun allowedImpliesEveryConditionHolds() {
        val rnd = Random(42)
        var allowed = 0
        repeat(20_000) {
            val f = file.copy(
                state = FileState.values()[rnd.nextInt(FileState.values().size)],
                tgMessageId = if (rnd.nextInt(8) == 0) null else 77L,
                tgChatId = if (rnd.nextInt(8) == 0) null else -1001L,
                deleteAfter = if (rnd.nextInt(6) == 0) null else now + rnd.nextLong(-3, 3),
                route = if (rnd.nextBoolean()) Route.BOT else Route.ACCOUNT,
            )
            val r = rule.copy(
                mode = RuleMode.values()[rnd.nextInt(2)],
                deleteWarningAcceptedAt = if (rnd.nextInt(5) == 0) null else 1L,
                enabled = rnd.nextInt(5) != 0,
                dryRun = rnd.nextBoolean(),
                deletedAt = if (rnd.nextInt(8) == 0) 3L else null,
            )
            val blocked = if (rnd.nextInt(6) == 0) "X" else null
            val d = DiskFacts(rnd.nextInt(6) != 0,
                if (rnd.nextInt(5) == 0) f.sizeBytes + 1 else f.sizeBytes,
                if (rnd.nextInt(5) == 0) f.modifiedAt + 1 else f.modifiedAt)
            val review = rnd.nextBoolean()
            val acct = AccountCheck.values()[rnd.nextInt(AccountCheck.values().size)]
            val botOnly = rnd.nextBoolean()
            val res = DeleteGate.check(f, r, blocked, d, now, review, acct, botOnly)
            if (res is GateResult.Allowed) {
                allowed++
                assertThat(f.state).isEqualTo(FileState.VERIFIED)
                assertThat(f.tgMessageId).isNotNull(); assertThat(f.tgChatId).isNotNull()
                assertThat(r.mode).isEqualTo(RuleMode.UPLOAD_AND_DELETE)
                assertThat(r.deleteWarningAcceptedAt).isNotNull()
                assertThat(r.enabled).isTrue(); assertThat(r.deletedAt).isNull()
                assertThat(blocked).isNull()
                assertThat(now).isAtLeast(f.deleteAfter!!)
                assertThat(!r.dryRun || review).isTrue()
                assertThat(d.exists).isTrue()
                assertThat(d.sizeBytes).isEqualTo(f.sizeBytes); assertThat(d.modifiedAt).isEqualTo(f.modifiedAt)
                assertThat(acct == AccountCheck.OK || (acct == AccountCheck.NOT_READY && botOnly && f.route == Route.BOT)).isTrue()
            }
        }
        assertThat(allowed).isGreaterThan(0)
    }
}
