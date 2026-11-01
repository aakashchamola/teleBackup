package com.aakashchamola.telebackup.core.telegram.account

import com.aakashchamola.telebackup.core.clean.AccountVerifier
import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.model.AccountCheck
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.TelegramSender
import com.aakashchamola.telebackup.core.telegram.TgError

/** Sends as the logged-in account (files over the 50 MB the bot can take). */
class AccountSender(private val auth: AccountAuth, private val gateway: TdGateway) : TelegramSender {
    override suspend fun send(job: SendJob, progress: (sent: Long, total: Long) -> Unit): SendResult =
        when (auth.ensureReady()) {
            AccountAuth.Readiness.Ready -> gateway.send(job, progress)
            AccountAuth.Readiness.NotLoggedIn -> SendResult.Failed(TgError.AccountLoggedOut)
            AccountAuth.Readiness.Offline -> SendResult.Failed(TgError.Network)
        }
}

/**
 * The strong check before a delete: ask Telegram for the message again, as the account, and compare it with what we stored.
 * Anything short of a clear answer is not OK, so the delete gate then refuses.
 */
class AccountRecheck(private val auth: AccountAuth, private val gateway: TdGateway) : AccountVerifier {
    override suspend fun recheck(file: FileEntity): AccountCheck {
        val chat = file.tgChatId ?: return AccountCheck.NOT_FOUND
        val msg = file.tgMessageId ?: return AccountCheck.NOT_FOUND
        when (auth.ensureReady()) {
            AccountAuth.Readiness.NotLoggedIn -> return AccountCheck.NOT_READY
            AccountAuth.Readiness.Offline -> return AccountCheck.UNAVAILABLE
            AccountAuth.Readiness.Ready -> Unit
        }
        return when (val r = gateway.fetch(chat, msg)) {
            TdFetch.NotFound -> AccountCheck.NOT_FOUND
            TdFetch.Unavailable -> AccountCheck.UNAVAILABLE
            is TdFetch.Found -> {
                val m = r.message
                val sameKind = file.sendAs == null || m.kind == file.sendAs
                // photos sent as media are re-encoded, so their byte size is not comparable; the file id is
                val sizeOk = if (m.kind == SendAs.PHOTO) true else file.tgSize != null && m.size == file.tgSize
                val idOk = file.tgFileUniqueId == null || m.fileUniqueId == null || file.tgFileUniqueId == m.fileUniqueId
                if (sameKind && sizeOk && idOk) AccountCheck.OK else AccountCheck.MISMATCH
            }
        }
    }
}
