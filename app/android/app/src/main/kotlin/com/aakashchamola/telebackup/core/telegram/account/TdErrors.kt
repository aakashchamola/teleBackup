package com.aakashchamola.telebackup.core.telegram.account

import com.aakashchamola.telebackup.core.telegram.TgError

/** Pure helpers for the TDLib adapter: they take plain numbers and text so they can be tested without the library. */
object TdErrors {
    private val retryAfter = Regex("retry after (\\d+)", RegexOption.IGNORE_CASE)

    /** TDLib error (code, message) from a send, as the error kind the upload loop acts on. */
    fun forSend(code: Int, message: String): TgError {
        val m = message.uppercase()
        return when {
            code == 429 || m.startsWith("FLOOD_WAIT") || "TOO MANY REQUESTS" in m ->
                TgError.FloodWait(retryAfter.find(message)?.groupValues?.get(1)?.toLongOrNull()
                    ?: Regex("FLOOD_WAIT_(\\d+)").find(m)?.groupValues?.get(1)?.toLongOrNull() ?: 30)
            code == 401 || "AUTH_KEY" in m || "SESSION_REVOKED" in m || "USER_DEACTIVATED" in m -> TgError.AccountLoggedOut
            "TOPIC_DELETED" in m || "TOPIC_ID_INVALID" in m || "MESSAGE_THREAD_INVALID" in m || "TOPIC_CLOSED" in m -> TgError.TopicMissing
            "CHAT_WRITE_FORBIDDEN" in m || "CHAT_ADMIN_REQUIRED" in m || "USER_BANNED_IN_CHANNEL" in m || code == 403 ->
                TgError.Forbidden(message)
            "FILE_PARTS_INVALID" in m || "FILE_TOO_BIG" in m || "FILE_SIZE_EXCEEDED" in m -> TgError.TooLarge
            code in 500..599 -> TgError.Server(code)
            code == 400 -> TgError.BadRequest(message)
            else -> TgError.Server(code)
        }
    }

    /** What the login screens say for a rejected step. Never shows Telegram's raw text. */
    fun forLogin(code: Int, message: String): String {
        val m = message.uppercase()
        return when {
            "PHONE_NUMBER_INVALID" in m || "PHONE_NUMBER_BANNED" in m -> "That phone number is not valid."
            "PHONE_CODE_INVALID" in m || "CODE_INVALID" in m -> "That code is not right."
            "PHONE_CODE_EXPIRED" in m || "CODE_EXPIRED" in m -> "That code has expired. Ask for a new one."
            "PASSWORD_HASH_INVALID" in m || "PASSWORD_INVALID" in m -> "That password is not right."
            code == 429 || "FLOOD" in m || "TOO MANY" in m -> {
                val s = retryAfter.find(message)?.groupValues?.get(1) ?: Regex("FLOOD_WAIT_(\\d+)").find(m)?.groupValues?.get(1)
                if (s != null) "Telegram says wait $s seconds, then try again." else "Too many tries. Wait a few minutes and try again."
            }
            "API_ID_INVALID" in m || "API_ID_PUBLISHED_FLOOD" in m -> "Telegram did not accept that api_id and api_hash."
            else -> "Telegram did not accept that. Try again."
        }
    }

    /** "+91 ••••• ••210": country digits kept out of it, only the last three digits shown. */
    fun maskPhone(phone: String?): String? {
        val d = phone?.filter { it.isDigit() } ?: return null
        if (d.length < 4) return null
        return "+•• ••••• ••" + d.takeLast(3)
    }
}
