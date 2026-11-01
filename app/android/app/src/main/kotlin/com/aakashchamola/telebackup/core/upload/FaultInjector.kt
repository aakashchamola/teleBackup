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
    override suspend fun sendAlbum(jobs: List<SendJob>, progress: (Long, Long) -> Unit): com.aakashchamola.telebackup.core.telegram.AlbumResult {
        FaultInjector.armed() ?: return inner.sendAlbum(jobs, progress)
        return com.aakashchamola.telebackup.core.telegram.AlbumResult.Unsupported   // an armed fault is spent by the single sends that follow
    }

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
