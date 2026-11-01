package com.aakashchamola.telebackup.core.verify

import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SentMessage
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

sealed class ReplyCheck {
    object Ok : ReplyCheck()
    data class Mismatch(val reason: String) : ReplyCheck()
}

/** Checks Telegram's reply to a send against what we sent (docs/TELEGRAM.md "Reply checks"). */
object Verifier {
    /** Photos sent as media are made smaller; the largest size must still be at least this long on its long side. */
    const val PHOTO_MIN_LONG_SIDE = 1280

    fun checkReply(job: SendJob, sent: SentMessage): ReplyCheck {
        if (sent.chatId != job.chatId) return ReplyCheck.Mismatch("wrong group")
        if (sent.threadId != job.threadId) return ReplyCheck.Mismatch("wrong topic")
        if (sent.messageId <= 0) return ReplyCheck.Mismatch("no message id")
        return when (job.sendAs) {
            SendAs.DOCUMENT ->
                if (sent.size == job.sizeBytes) ReplyCheck.Ok
                else ReplyCheck.Mismatch("size ${sent.size} instead of ${job.sizeBytes}")
            SendAs.VIDEO -> checkVideo(job, sent)
            SendAs.PHOTO -> checkPhoto(job, sent)
        }
    }

    private fun checkVideo(job: SendJob, sent: SentMessage): ReplyCheck {
        val wantDur = job.durationMs
        val gotDur = sent.durationMs
        if (wantDur != null && gotDur != null && abs(wantDur - gotDur) > 1000) {
            return ReplyCheck.Mismatch("duration differs")
        }
        val w = job.width; val h = job.height
        if (w != null && h != null && sent.width != null && sent.height != null) {
            val same = sent.width == w && sent.height == h
            val swapped = sent.width == h && sent.height == w
            if (!same && !swapped) return ReplyCheck.Mismatch("video size differs")
        }
        if (sent.size == null || sent.size <= 0) return ReplyCheck.Mismatch("no size reported")
        return ReplyCheck.Ok
    }

    private fun checkPhoto(job: SendJob, sent: SentMessage): ReplyCheck {
        val gw = sent.width; val gh = sent.height
        if (gw == null || gh == null || gw <= 0 || gh <= 0) return ReplyCheck.Mismatch("no photo size reported")
        val w = job.width; val h = job.height
        if (w != null && h != null && w > 0 && h > 0) {
            val wantRatio = w.toDouble() / h
            val gotRatio = gw.toDouble() / gh
            val swappedRatio = h.toDouble() / w
            val close = abs(gotRatio - wantRatio) / wantRatio <= 0.01 ||
                abs(gotRatio - swappedRatio) / swappedRatio <= 0.01
            if (!close) return ReplyCheck.Mismatch("photo shape differs")
            val needLong = min(max(w, h), PHOTO_MIN_LONG_SIDE)
            if (max(gw, gh) < needLong) return ReplyCheck.Mismatch("photo too small")
        }
        return ReplyCheck.Ok
    }
}
