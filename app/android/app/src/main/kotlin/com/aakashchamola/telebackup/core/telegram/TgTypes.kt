package com.aakashchamola.telebackup.core.telegram

import com.aakashchamola.telebackup.core.model.SendAs

/** What went wrong talking to Telegram. The upload loop acts on the kind, never on text. */
sealed class TgError(val userMessage: String) {
    data class FloodWait(val seconds: Long) : TgError("Telegram asked us to slow down for $seconds seconds.")
    object TooLarge : TgError("The file is too big for the bot.")
    object TopicMissing : TgError("The topic was deleted in Telegram.")
    data class ChatMigrated(val newChatId: Long) : TgError("The group moved to a new id.")
    data class BadRequest(val description: String) : TgError("Telegram refused the file: $description")
    object BadToken : TgError("The bot token no longer works.")
    data class Forbidden(val description: String) : TgError("The bot cannot post to the group: $description")
    data class Server(val code: Int, val consecutive: Int = 1) : TgError("Telegram had a problem ($code).")
    object Network : TgError("No connection to Telegram.")
    object AccountLoggedOut : TgError("The Telegram account is logged out.")
}

/** One file to send. */
data class SendJob(
    val chatId: Long,
    val threadId: Long?,
    val path: String,
    val displayName: String,
    val mimeType: String,
    val sendAs: SendAs,
    val caption: String,
    val sizeBytes: Long,
    val width: Int? = null,
    val height: Int? = null,
    val durationMs: Long? = null,
)

/** What Telegram reported back, in Bot API form. */
data class SentMessage(
    val chatId: Long,
    val threadId: Long?,
    val messageId: Long,
    val fileUniqueId: String?,
    val size: Long?,
    val width: Int?,
    val height: Int?,
    val durationMs: Long?,
    val kind: SendAs,
)

sealed class SendResult {
    data class Sent(val message: SentMessage) : SendResult()
    data class Failed(val error: TgError) : SendResult()
}

interface TelegramSender {
    suspend fun send(job: SendJob, progress: (sent: Long, total: Long) -> Unit): SendResult
}

/** Bot API message ids and TDLib message ids differ by 20 bits for supergroup messages. */
object TdIds {
    private const val SHIFT = 20
    fun toTdlib(botApiMessageId: Long): Long = botApiMessageId shl SHIFT
    fun fromTdlib(tdlibMessageId: Long): Long = tdlibMessageId shr SHIFT
}
