package com.aakashchamola.telebackup.core.model

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.telegram.SentMessage
import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.time.Time

class IllegalTransition(val from: FileState, val event: FileEvent) :
    IllegalStateException("Cannot apply ${event::class.simpleName} to a $from file")

sealed class FileEvent {
    object StartUpload : FileEvent()
    object NetworkStop : FileEvent()
    data class Sent(val message: SentMessage, val sha256: String?) : FileEvent()
    data class ReplyOk(val deleteAfter: Long?) : FileEvent()
    data class ReplyMismatch(val reason: String) : FileEvent()
    data class TgFailed(val error: TgError) : FileEvent()
    object BackoffDue : FileEvent()
    object GiveUp : FileEvent()
    object RetryByPerson : FileEvent()
    object Changed : FileEvent()
    object Vanished : FileEvent()
    object Ignore : FileEvent()
    object RecoverAfterCrash : FileEvent()
    /** The Telegram message is gone or does not match: upload the file again. */
    object TelegramLost : FileEvent()
    /** Needs a permit that only [DeleteGate] can hand out. */
    data class DeletedByCleaner(val permit: GateResult.Allowed, val freedBytes: Long) : FileEvent()
}

/** After a failed attempt number [attempt] (1, 2, 3...), how long to wait: 2^n minutes up to 6 hours, plus up to 20%. */
object Backoff {
    fun delayMillis(attempt: Int, jitter01: Double = 0.0): Long {
        val minutes = 1L shl attempt.coerceIn(0, 20)
        val base = minOf(minutes * Time.MINUTE, 6 * Time.HOUR)
        return base + (base * 0.2 * jitter01.coerceIn(0.0, 1.0)).toLong()
    }
}

/**
 * The only place a file's state changes (docs/DATA_MODEL.md "File state machine").
 * Pure: returns the new row or throws [IllegalTransition].
 */
object FileStateMachine {
    const val DEFAULT_MAX_ATTEMPTS = 5

    fun transition(
        file: FileEntity,
        event: FileEvent,
        now: Long,
        maxAttempts: Int = DEFAULT_MAX_ATTEMPTS,
        jitter01: Double = 0.0,
    ): FileEntity {
        val s = file.state
        val next: FileEntity = when (event) {
            FileEvent.StartUpload -> {
                require(s == FileState.QUEUED, s, event)
                file.copy(state = FileState.UPLOADING)
            }
            FileEvent.NetworkStop -> {
                require(s == FileState.UPLOADING, s, event)
                file.copy(state = FileState.QUEUED)
            }
            is FileEvent.Sent -> {
                require(s == FileState.UPLOADING, s, event)
                val m = event.message
                file.copy(
                    state = FileState.UPLOADED,
                    sha256 = event.sha256 ?: file.sha256,
                    sendAs = m.kind,
                    tgChatId = m.chatId,
                    tgThreadId = m.threadId,
                    tgMessageId = m.messageId,
                    tgFileUniqueId = m.fileUniqueId,
                    tgSize = m.size,
                    tgWidth = m.width,
                    tgHeight = m.height,
                    tgDurationMs = m.durationMs,
                    uploadedAt = now,
                    lastError = null,
                )
            }
            is FileEvent.ReplyOk -> {
                require(s == FileState.UPLOADED, s, event)
                file.copy(state = FileState.VERIFIED, verifiedAt = now, deleteAfter = event.deleteAfter, attempts = 0, nextAttemptAt = null)
            }
            is FileEvent.ReplyMismatch -> {
                require(s == FileState.UPLOADED, s, event)
                countedFailure(file, "Telegram's reply did not match: ${event.reason}", now, maxAttempts, jitter01, clearTelegram = true)
            }
            is FileEvent.TgFailed -> {
                require(s == FileState.UPLOADING, s, event)
                failed(file, event.error, now, maxAttempts, jitter01)
            }
            FileEvent.BackoffDue -> {
                require(s == FileState.FAILED, s, event)
                file.copy(state = FileState.QUEUED)
            }
            FileEvent.GiveUp -> {
                require(s == FileState.FAILED, s, event)
                file.copy(state = FileState.SKIPPED, nextAttemptAt = null)
            }
            FileEvent.RetryByPerson -> {
                require(s == FileState.SKIPPED || s == FileState.FAILED, s, event)
                file.copy(state = FileState.QUEUED, attempts = 0, nextAttemptAt = null, lastError = null)
            }
            FileEvent.Changed -> {
                require(s == FileState.VERIFIED, s, event)
                file.copy(state = FileState.CHANGED, deleteAfter = null)
            }
            FileEvent.Vanished -> {
                require(s == FileState.QUEUED || s == FileState.UPLOADING || s == FileState.FAILED ||
                    s == FileState.SKIPPED || s == FileState.VERIFIED, s, event)
                file.copy(state = FileState.GONE, deleteAfter = null)
            }
            FileEvent.Ignore -> {
                require(s == FileState.QUEUED || s == FileState.FAILED || s == FileState.SKIPPED, s, event)
                file.copy(state = FileState.IGNORED, nextAttemptAt = null)
            }
            FileEvent.RecoverAfterCrash -> {
                require(s == FileState.UPLOADING, s, event)
                if (file.tgMessageId != null) file.copy(state = FileState.UPLOADED)
                else file.copy(state = FileState.QUEUED)
            }
            FileEvent.TelegramLost -> {
                require(s == FileState.VERIFIED, s, event)
                clearTelegram(file.copy(state = FileState.QUEUED, deleteAfter = null, verifiedAt = null, uploadedAt = null))
            }
            is FileEvent.DeletedByCleaner -> {
                require(s == FileState.VERIFIED, s, event)
                require(event.permit.fileId == file.id) { "Permit is for another file" }
                file.copy(state = FileState.DELETED, deletedAt = now, freedBytes = event.freedBytes, deleteAfter = null)
            }
        }
        return next.copy(updatedAt = now)
    }

    private fun require(ok: Boolean, s: FileState, e: FileEvent) {
        if (!ok) throw IllegalTransition(s, e)
    }

    private fun failed(file: FileEntity, err: TgError, now: Long, max: Int, jitter: Double): FileEntity {
        val back = file.copy(state = FileState.QUEUED, lastError = err.userMessage)
        return when (err) {
            is TgError.FloodWait -> back.copy(nextAttemptAt = now + (err.seconds + 1) * 1000)
            TgError.TooLarge ->
                if (file.route == Route.BOT) back.copy(route = Route.ACCOUNT)
                else file.copy(state = FileState.SKIPPED, lastError = "Too big for Telegram.", nextAttemptAt = null)
            is TgError.BadRequest -> countedFailure(file, err.userMessage, now, max, jitter)
            is TgError.Server ->
                if (err.consecutive >= 3) countedFailure(file, err.userMessage, now, max, jitter)
                else back.copy(nextAttemptAt = now + 30_000)
            TgError.TopicMissing, TgError.BadToken, is TgError.Forbidden, is TgError.ChatMigrated,
            TgError.Network, TgError.AccountLoggedOut -> back
        }
    }

    private fun countedFailure(
        file: FileEntity, message: String, now: Long, max: Int, jitter: Double, clearTelegram: Boolean = false,
    ): FileEntity {
        val attempts = file.attempts + 1
        val base = if (clearTelegram) clearTelegram(file) else file
        return if (attempts >= max) {
            base.copy(state = FileState.SKIPPED, attempts = attempts, lastError = message, nextAttemptAt = null)
        } else {
            base.copy(state = FileState.FAILED, attempts = attempts, lastError = message,
                nextAttemptAt = now + Backoff.delayMillis(attempts, jitter))
        }
    }

    private fun clearTelegram(f: FileEntity) = f.copy(
        tgChatId = null, tgThreadId = null, tgMessageId = null, tgFileUniqueId = null,
        tgSize = null, tgWidth = null, tgHeight = null, tgDurationMs = null,
        uploadedAt = null, verifiedAt = null,
    )
}
