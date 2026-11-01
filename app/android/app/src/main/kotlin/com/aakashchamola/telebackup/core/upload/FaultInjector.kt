package com.aakashchamola.telebackup.core.upload

import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.TelegramSender
import com.aakashchamola.telebackup.core.telegram.TgError
import java.util.concurrent.atomic.AtomicReference

/** Debug builds only: makes the next send fail in a chosen way, to test the error paths on the phone (S-DEV). */
object FaultInjector {
    private val next = AtomicReference<String?>(null)
    fun arm(kind: String?) = next.set(kind)
    fun armed(): String? = next.get()
    fun take(): String? = next.getAndSet(null)
}

class FaultySender(private val inner: TelegramSender) : TelegramSender {
    override suspend fun send(job: SendJob, progress: (Long, Long) -> Unit): SendResult {
        val fault = FaultInjector.take() ?: return inner.send(job, progress)
        return SendResult.Failed(
            when (fault) {
                "429" -> TgError.FloodWait(30)
                "500" -> TgError.Server(500, 3)
                "network" -> TgError.Network
                "topic" -> TgError.TopicMissing
                "token" -> TgError.BadToken
                else -> TgError.BadRequest("injected: $fault")
            },
        )
    }
}
