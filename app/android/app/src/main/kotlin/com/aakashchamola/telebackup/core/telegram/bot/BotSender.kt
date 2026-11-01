package com.aakashchamola.telebackup.core.telegram.bot

import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.TelegramSender

/** Sends files with the Bot API (files under 50 MB). */
class BotSender(private val api: BotApi) : TelegramSender {
    override suspend fun send(job: SendJob, progress: (sent: Long, total: Long) -> Unit): SendResult =
        when (val r = api.sendFile(job, progress)) {
            is ApiResult.Ok -> SendResult.Sent(r.value)
            is ApiResult.Err -> SendResult.Failed(r.error)
        }
}
