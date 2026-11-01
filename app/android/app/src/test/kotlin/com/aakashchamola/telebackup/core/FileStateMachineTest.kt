package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.telegram.TgError
import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test

class FileStateMachineTest {
    private val now = Fx.NOW

    private fun t(f: com.aakashchamola.telebackup.core.db.FileEntity, e: FileEvent) =
        FileStateMachine.transition(f, e, now)

    private val permit get() = allowedPermit()

    /** The only way to get a permit is through the gate, so make one the proper way. */
    private fun allowedPermit(): GateResult.Allowed {
        val f = Fx.file(state = FileState.VERIFIED)
        val r = DeleteGate.check(f, Fx.rule(), null, DiskFacts(true, f.sizeBytes, f.modifiedAt), now, true, AccountCheck.OK, false)
        return r as GateResult.Allowed
    }

    private fun events(): List<FileEvent> = listOf(
        FileEvent.StartUpload, FileEvent.NetworkStop, FileEvent.Sent(Fx.sent(), "abc"), FileEvent.ReplyOk(null),
        FileEvent.ReplyMismatch("x"), FileEvent.TgFailed(TgError.Network), FileEvent.BackoffDue, FileEvent.GiveUp,
        FileEvent.RetryByPerson, FileEvent.Changed, FileEvent.Vanished, FileEvent.Ignore, FileEvent.RecoverAfterCrash,
        FileEvent.TelegramLost, FileEvent.DeletedByCleaner(permit, 10),
    )

    /** Every allowed (state, event) pair and where it goes. Everything else must throw. */
    private val allowed: Map<Pair<FileState, String>, FileState> = mapOf(
        (FileState.QUEUED to "StartUpload") to FileState.UPLOADING,
        (FileState.QUEUED to "Vanished") to FileState.GONE,
        (FileState.QUEUED to "Ignore") to FileState.IGNORED,
        (FileState.UPLOADING to "NetworkStop") to FileState.QUEUED,
        (FileState.UPLOADING to "Sent") to FileState.UPLOADED,
        (FileState.UPLOADING to "TgFailed") to FileState.QUEUED,
        (FileState.UPLOADING to "Vanished") to FileState.GONE,
        (FileState.UPLOADING to "RecoverAfterCrash") to FileState.QUEUED,
        (FileState.UPLOADED to "ReplyOk") to FileState.VERIFIED,
        (FileState.UPLOADED to "ReplyMismatch") to FileState.FAILED,
        (FileState.FAILED to "BackoffDue") to FileState.QUEUED,
        (FileState.FAILED to "GiveUp") to FileState.SKIPPED,
        (FileState.FAILED to "RetryByPerson") to FileState.QUEUED,
        (FileState.FAILED to "Ignore") to FileState.IGNORED,
        (FileState.FAILED to "Vanished") to FileState.GONE,
        (FileState.SKIPPED to "RetryByPerson") to FileState.QUEUED,
        (FileState.SKIPPED to "Ignore") to FileState.IGNORED,
        (FileState.SKIPPED to "Vanished") to FileState.GONE,
        (FileState.VERIFIED to "Changed") to FileState.CHANGED,
        (FileState.VERIFIED to "Vanished") to FileState.GONE,
        (FileState.VERIFIED to "TelegramLost") to FileState.QUEUED,
        (FileState.VERIFIED to "DeletedByCleaner") to FileState.DELETED,
    )

    @Test fun everyStateAndEventPair() {
        for (state in FileState.values()) {
            for (event in events()) {
                val name = event::class.simpleName!!
                val file = Fx.file(state = state, verified = state == FileState.VERIFIED)
                val dest = allowed[state to name]
                if (dest == null) {
                    assertThrows("$state + $name should be illegal", IllegalTransition::class.java) { t(file, event) }
                } else {
                    assertThat(t(file, event).state).isEqualTo(dest)
                }
            }
        }
    }

    @Test fun terminalStatesAcceptNothing() {
        for (s in FileState.values().filter { it.terminal }) {
            for (e in events()) {
                assertThrows(IllegalTransition::class.java) { t(Fx.file(state = s), e) }
            }
        }
    }

    @Test fun deletedIsOnlyReachableFromVerifiedWithAPermit() {
        val reachers = FileState.values().filter { s ->
            events().any { e -> runCatching { t(Fx.file(state = s, verified = s == FileState.VERIFIED), e).state }.getOrNull() == FileState.DELETED }
        }
        assertThat(reachers).containsExactly(FileState.VERIFIED)
    }

    @Test fun permitIsForOneFileOnly() {
        val p = permit // for file id 1
        val other = Fx.file(id = 2, state = FileState.VERIFIED)
        assertThrows(IllegalArgumentException::class.java) { t(other, FileEvent.DeletedByCleaner(p, 1)) }
    }

    @Test fun crashRecoveryUploadingBecomesQueuedOrUploaded() {
        val noMsg = Fx.file(state = FileState.UPLOADING)
        assertThat(t(noMsg, FileEvent.RecoverAfterCrash).state).isEqualTo(FileState.QUEUED)
        val withMsg = noMsg.copy(tgMessageId = 9, tgChatId = -1001)
        assertThat(t(withMsg, FileEvent.RecoverAfterCrash).state).isEqualTo(FileState.UPLOADED)
        assertThat(t(noMsg, FileEvent.RecoverAfterCrash).attempts).isEqualTo(noMsg.attempts)
    }

    @Test fun sentSavesTelegramFieldsAndReplyOkSetsDeleteAfter() {
        val up = t(Fx.file(state = FileState.UPLOADING), FileEvent.Sent(Fx.sent(id = 99), "hash"))
        assertThat(up.tgMessageId).isEqualTo(99)
        assertThat(up.sha256).isEqualTo("hash")
        assertThat(up.uploadedAt).isEqualTo(now)
        val ver = t(up, FileEvent.ReplyOk(now + 7 * Fx.DAY))
        assertThat(ver.state).isEqualTo(FileState.VERIFIED)
        assertThat(ver.deleteAfter).isEqualTo(now + 7 * Fx.DAY)
    }

    @Test fun networkAndBotProblemsDoNotCountAsAttempts() {
        val up = Fx.file(state = FileState.UPLOADING).copy(attempts = 2)
        for (err in listOf(TgError.Network, TgError.BadToken, TgError.TopicMissing, TgError.Forbidden("x"),
            TgError.ChatMigrated(-5), TgError.AccountLoggedOut)) {
            val r = t(up, FileEvent.TgFailed(err))
            assertThat(r.state).isEqualTo(FileState.QUEUED)
            assertThat(r.attempts).isEqualTo(2)
        }
    }

    @Test fun floodWaitWaitsButDoesNotCount() {
        val r = t(Fx.file(state = FileState.UPLOADING), FileEvent.TgFailed(TgError.FloodWait(30)))
        assertThat(r.state).isEqualTo(FileState.QUEUED)
        assertThat(r.attempts).isEqualTo(0)
        assertThat(r.nextAttemptAt).isEqualTo(now + 31_000)
    }

    @Test fun tooLargeMovesBotFileToAccountThenSkips() {
        val bot = Fx.file(state = FileState.UPLOADING, route = Route.BOT)
        val r1 = t(bot, FileEvent.TgFailed(TgError.TooLarge))
        assertThat(r1.state).isEqualTo(FileState.QUEUED)
        assertThat(r1.route).isEqualTo(Route.ACCOUNT)
        val r2 = t(r1.copy(state = FileState.UPLOADING), FileEvent.TgFailed(TgError.TooLarge))
        assertThat(r2.state).isEqualTo(FileState.SKIPPED)
    }

    @Test fun badRequestCountsThenSkipsAtMax() {
        var f = Fx.file(state = FileState.UPLOADING)
        for (i in 1 until FileStateMachine.DEFAULT_MAX_ATTEMPTS) {
            f = t(f, FileEvent.TgFailed(TgError.BadRequest("nope")))
            assertThat(f.state).isEqualTo(FileState.FAILED)
            assertThat(f.attempts).isEqualTo(i)
            assertThat(f.nextAttemptAt).isGreaterThan(now)
            f = t(f, FileEvent.BackoffDue).copy(state = FileState.UPLOADING)
        }
        f = t(f, FileEvent.TgFailed(TgError.BadRequest("nope")))
        assertThat(f.state).isEqualTo(FileState.SKIPPED)
    }

    @Test fun serverErrorCountsOnlyAfterThreeInARow() {
        val up = Fx.file(state = FileState.UPLOADING)
        assertThat(t(up, FileEvent.TgFailed(TgError.Server(502, 1))).attempts).isEqualTo(0)
        assertThat(t(up, FileEvent.TgFailed(TgError.Server(502, 3))).attempts).isEqualTo(1)
    }

    @Test fun replyMismatchFailsAndForgetsTheMessage() {
        val up = t(Fx.file(state = FileState.UPLOADING), FileEvent.Sent(Fx.sent(), null))
        val r = t(up, FileEvent.ReplyMismatch("size"))
        assertThat(r.state).isEqualTo(FileState.FAILED)
        assertThat(r.tgMessageId).isNull()
        assertThat(r.attempts).isEqualTo(1)
    }

    @Test fun telegramLostSendsAVerifiedFileBackToTheQueue() {
        val r = t(Fx.file(state = FileState.VERIFIED), FileEvent.TelegramLost)
        assertThat(r.state).isEqualTo(FileState.QUEUED)
        assertThat(r.tgMessageId).isNull()
        assertThat(r.deleteAfter).isNull()
    }

    @Test fun retryByPersonResetsAttempts() {
        val sk = Fx.file(state = FileState.SKIPPED).copy(attempts = 5, lastError = "x")
        val r = t(sk, FileEvent.RetryByPerson)
        assertThat(r.state).isEqualTo(FileState.QUEUED)
        assertThat(r.attempts).isEqualTo(0)
        assertThat(r.lastError).isNull()
    }

    @Test fun deletedRecordsFreedBytes() {
        val f = Fx.file(state = FileState.VERIFIED)
        val p = DeleteGate.check(f, Fx.rule(), null, DiskFacts(true, f.sizeBytes, f.modifiedAt), now, true, AccountCheck.OK, false) as GateResult.Allowed
        val r = t(f, FileEvent.DeletedByCleaner(p, f.sizeBytes))
        assertThat(r.state).isEqualTo(FileState.DELETED)
        assertThat(r.freedBytes).isEqualTo(f.sizeBytes)
        assertThat(r.deletedAt).isEqualTo(now)
    }
}
