package com.aakashchamola.telebackup.core.telegram.account

import com.aakashchamola.telebackup.core.telegram.AlbumResult
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.SentMessage
import kotlinx.coroutines.flow.StateFlow
import java.io.File

/** Where TDLib is in its login, in our words (a thin copy of TDLib's AuthorizationState). */
sealed class TdAuth {
    /** No client is running. */
    object Closed : TdAuth()
    /** The client is open and wants its parameters (api id and hash, database folder). */
    object WaitParams : TdAuth()
    object WaitPhone : TdAuth()
    data class WaitCode(val sentTo: String?) : TdAuth()
    data class WaitPassword(val hint: String?) : TdAuth()
    /** Something we do not handle (e-mail code, sign-up). The text says what Telegram wants. */
    data class WaitOther(val what: String) : TdAuth()
    data class Ready(val name: String, val phoneMasked: String?) : TdAuth()
    /** The session was ended (by the user in Telegram, or by [TdGateway.logOut]). */
    object LoggedOut : TdAuth()
}

/** Folders and keys for one TDLib client. The database lives in no-backup storage. */
data class TdParams(val apiId: Int, val apiHash: String, val databaseDir: File, val filesDir: File, val databaseKey: String)

/** Answer to one login step. [message] is plain words for the screen. */
sealed class TdStep {
    object Ok : TdStep()
    data class Rejected(val message: String) : TdStep()
    object Network : TdStep()
}

/** What re-fetching a message found. All ids are in Bot API form. */
sealed class TdFetch {
    data class Found(val message: SentMessage) : TdFetch()
    object NotFound : TdFetch()
    object Unavailable : TdFetch()
}

/**
 * The only thing the app knows about TDLib. The real one wraps `org.drinkless.tdlib`; tests use a fake.
 * Message ids in and out are Bot API ids; the gateway does the 20-bit shift (see TdIds).
 */
interface TdGateway {
    val auth: StateFlow<TdAuth>
    /** Starts a client with its parameters. A saved session goes straight to [TdAuth.Ready]. */
    suspend fun open(params: TdParams)
    suspend fun submitPhone(phone: String): TdStep
    suspend fun submitCode(code: String): TdStep
    suspend fun submitPassword(password: String): TdStep
    suspend fun resendCode(): TdStep
    /** Sends one file as the logged-in account. Errors come back as [SendResult.Failed] with a TgError. */
    suspend fun send(job: SendJob, progress: (sent: Long, total: Long) -> Unit): SendResult
    /** 2 to 10 files shown together, as the account (a video cut into parts). Default: not supported. */
    suspend fun sendAlbum(jobs: List<SendJob>, progress: (sent: Long, total: Long) -> Unit): AlbumResult = AlbumResult.Unsupported

    /** Asks Telegram for a message again (the group must be known to the account). */
    suspend fun fetch(chatId: Long, botApiMessageId: Long): TdFetch
    /** Ends the session on the Telegram side and wipes the local database. */
    suspend fun logOut()
    /** Stops the client but keeps the session on disk. */
    fun close()
}
