package com.aakashchamola.telebackup.core.telegram.account

import android.os.Build
import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.SentMessage
import com.aakashchamola.telebackup.core.telegram.TdIds
import com.aakashchamola.telebackup.core.telegram.TgError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume

/**
 * The real [TdGateway]: TDLib (org.drinkless.tdlib) behind the seam. TDLib runs in its own thread; this class turns its
 * callbacks into coroutines. The database is encrypted with a key from the secret store and lives in no-backup storage.
 * Logging is off (TDLib's log can hold personal data). Written against TDLib 1.8.67 (docs/M1_FINDINGS.md).
 */
class TdlibGateway(private val appVersion: String) : TdGateway {
    private val state = MutableStateFlow<TdAuth>(TdAuth.Closed)
    override val auth: StateFlow<TdAuth> get() = state

    @Volatile private var client: Client? = null
    @Volatile private var params: TdParams? = null
    @Volatile private var loggingOut = false
    private val lock = Any()

    private class Upload(val total: Long, val progress: (Long, Long) -> Unit)
    private val uploadsByFile = ConcurrentHashMap<Int, Upload>()
    private val sendWaiters = ConcurrentHashMap<Long, CompletableDeferred<TdApi.Message>>()
    private val sendFailures = ConcurrentHashMap<Long, TdApi.Error>()

    // ----- life of the client -----

    override suspend fun open(params: TdParams) {
        synchronized(lock) {
            if (client != null) return
            this.params = params
            loggingOut = false
            runCatching { Client.execute(TdApi.SetLogVerbosityLevel(0)) }
            state.value = TdAuth.WaitParams
            client = Client.create({ onUpdate(it) }, { Tlog.w("tdlib exception: ${it.javaClass.simpleName}") }, { Tlog.w("tdlib exception: ${it.javaClass.simpleName}") })
        }
    }

    override fun close() {
        val c = client ?: return
        c.send(TdApi.Close()) { }
    }

    override suspend fun logOut() {
        val c = client ?: return
        loggingOut = true
        c.send(TdApi.LogOut()) { }
    }

    private fun onUpdate(o: TdApi.Object) {
        when (o) {
            is TdApi.UpdateAuthorizationState -> onAuthState(o.authorizationState)
            is TdApi.UpdateFile -> uploadsByFile[o.file.id]?.let { u ->
                val sent = o.file.remote?.uploadedSize ?: 0
                u.progress(sent.coerceAtMost(u.total), u.total)
            }
            is TdApi.UpdateMessageSendSucceeded -> sendWaiters.remove(o.oldMessageId)?.complete(o.message)
            is TdApi.UpdateMessageSendFailed -> {
                sendFailures[o.oldMessageId] = o.error
                sendWaiters.remove(o.oldMessageId)?.completeExceptionally(SendFailed(o.error))
            }
            else -> Unit
        }
    }

    private class SendFailed(val error: TdApi.Error) : Exception()

    private fun onAuthState(s: TdApi.AuthorizationState) {
        when (s) {
            is TdApi.AuthorizationStateWaitTdlibParameters -> sendParameters()
            is TdApi.AuthorizationStateWaitPhoneNumber -> state.value = TdAuth.WaitPhone
            is TdApi.AuthorizationStateWaitCode -> state.value = TdAuth.WaitCode(sentTo(s.codeInfo?.type))
            is TdApi.AuthorizationStateWaitPassword -> state.value = TdAuth.WaitPassword(s.passwordHint?.takeIf { it.isNotBlank() })
            is TdApi.AuthorizationStateWaitEmailAddress, is TdApi.AuthorizationStateWaitEmailCode ->
                state.value = TdAuth.WaitOther("Telegram wants an e-mail login for this account. That is not supported yet; turn it off in Telegram and try again.")
            is TdApi.AuthorizationStateWaitRegistration ->
                state.value = TdAuth.WaitOther("This phone number has no Telegram account yet. Make one in the Telegram app first.")
            is TdApi.AuthorizationStateWaitOtherDeviceConfirmation, is TdApi.AuthorizationStateWaitPremiumPurchase ->
                state.value = TdAuth.WaitOther("Telegram wants a confirmation this app cannot give.")
            is TdApi.AuthorizationStateReady -> readyWithName()
            is TdApi.AuthorizationStateLoggingOut -> loggingOut = true
            is TdApi.AuthorizationStateClosed -> {
                client = null
                uploadsByFile.clear()
                state.value = if (loggingOut) TdAuth.LoggedOut else TdAuth.Closed
                loggingOut = false
            }
            else -> Unit
        }
    }

    private fun sentTo(t: TdApi.AuthenticationCodeType?): String = when (t) {
        is TdApi.AuthenticationCodeTypeTelegramMessage -> "Telegram app"
        is TdApi.AuthenticationCodeTypeSms, is TdApi.AuthenticationCodeTypeSmsWord, is TdApi.AuthenticationCodeTypeSmsPhrase -> "SMS"
        is TdApi.AuthenticationCodeTypeCall, is TdApi.AuthenticationCodeTypeFlashCall, is TdApi.AuthenticationCodeTypeMissedCall -> "a phone call"
        else -> "Telegram"
    }

    private fun sendParameters() {
        val p = params ?: return
        val r = TdApi.SetTdlibParameters().apply {
            useTestDc = false
            databaseDirectory = p.databaseDir.absolutePath
            filesDirectory = p.filesDir.absolutePath
            databaseEncryptionKey = p.databaseKey.toByteArray(Charsets.UTF_8)
            useFileDatabase = true
            useChatInfoDatabase = true
            useMessageDatabase = false
            useSecretChats = false
            apiId = p.apiId
            apiHash = p.apiHash
            systemLanguageCode = "en"
            deviceModel = Build.MODEL
            systemVersion = Build.VERSION.RELEASE
            applicationVersion = appVersion
        }
        client?.send(r) { res -> if (res is TdApi.Error) { Tlog.w("setTdlibParameters failed: ${res.code}"); state.value = TdAuth.WaitOther(TdErrors.forLogin(res.code, res.message)) } }
    }

    private fun readyWithName() {
        client?.send(TdApi.GetMe()) { res ->
            val u = res as? TdApi.User
            val name = listOfNotNull(u?.firstName, u?.lastName).joinToString(" ").trim().ifEmpty { "Telegram account" }
            state.value = TdAuth.Ready(name, TdErrors.maskPhone(u?.phoneNumber))
        } ?: run { state.value = TdAuth.Ready("Telegram account", null) }
    }

    // ----- login steps -----

    private suspend fun call(f: TdApi.Function<*>): TdApi.Object? {
        val c = client ?: return null
        return suspendCancellableCoroutine { k -> c.send(f) { k.resume(it) } }
    }

    private suspend fun step(f: TdApi.Function<*>): TdStep = when (val r = call(f)) {
        null -> TdStep.Network
        is TdApi.Error -> if (r.code == 500 && r.message.contains("network", true)) TdStep.Network else TdStep.Rejected(TdErrors.forLogin(r.code, r.message))
        else -> TdStep.Ok
    }

    override suspend fun submitPhone(phone: String) = step(TdApi.SetAuthenticationPhoneNumber(phone, TdApi.PhoneNumberAuthenticationSettings()))
    override suspend fun submitCode(code: String) = step(TdApi.CheckAuthenticationCode(code))
    override suspend fun submitPassword(password: String) = step(TdApi.CheckAuthenticationPassword(password))
    override suspend fun resendCode() = step(TdApi.ResendAuthenticationCode(TdApi.ResendCodeReasonUserRequest()))

    // ----- sending -----

    /** TDLib only knows a chat it has loaded; ask for the chat list first when it does not know this one yet. */
    private suspend fun knowChat(chatId: Long): Boolean {
        if (call(TdApi.GetChat(chatId)) is TdApi.Chat) return true
        call(TdApi.GetChats(TdApi.ChatListMain(), 200))
        return call(TdApi.GetChat(chatId)) is TdApi.Chat
    }

    override suspend fun send(job: SendJob, progress: (sent: Long, total: Long) -> Unit): SendResult {
        if (client == null) return SendResult.Failed(TgError.AccountLoggedOut)
        if (!knowChat(job.chatId)) return SendResult.Failed(TgError.Forbidden("the account cannot see the group; add the account to it"))
        val file = TdApi.InputFileLocal(job.path)
        val caption = TdApi.FormattedText(job.caption, emptyArray())
        val content: TdApi.InputMessageContent = when (job.sendAs) {
            SendAs.DOCUMENT -> TdApi.InputMessageDocument(TdApi.InputDocument(file, null, true), caption)
            SendAs.VIDEO -> TdApi.InputMessageVideo(
                TdApi.InputVideo(file, null, null, 0, IntArray(0), ((job.durationMs ?: 0) / 1000).toInt(), job.width ?: 0, job.height ?: 0, true),
                caption, false, null, false,
            )
            SendAs.PHOTO -> return SendResult.Failed(TgError.BadRequest("photos go through the bot"))
        }
        val topic = job.threadId?.let { TdApi.MessageTopicForum(it.toInt()) }
        val options = TdApi.MessageSendOptions().apply { disableNotification = true; fromBackground = true }
        val first = call(TdApi.SendMessage(job.chatId, topic, null, options, null, content))
        if (first is TdApi.Error) return SendResult.Failed(TdErrors.forSend(first.code, first.message))
        val pending = first as? TdApi.Message ?: return SendResult.Failed(TgError.Network)

        val waiter = CompletableDeferred<TdApi.Message>()
        sendWaiters[pending.id] = waiter
        val fileId = fileOf(pending.content)?.id
        if (fileId != null) uploadsByFile[fileId] = Upload(job.sizeBytes, progress)
        // the update may have come before we registered
        sendFailures.remove(pending.id)?.let { return SendResult.Failed(TdErrors.forSend(it.code, it.message)) }
        try {
            val done = waiter.await()
            return toSent(done)?.let { SendResult.Sent(it) } ?: SendResult.Failed(TgError.BadRequest("Telegram answered with something that is not the file"))
        } catch (e: SendFailed) {
            return SendResult.Failed(TdErrors.forSend(e.error.code, e.error.message))
        } finally {
            sendWaiters.remove(pending.id)
            fileId?.let { uploadsByFile.remove(it) }
            if (!waiter.isCompleted) {   // cancelled while sending: stop the upload and drop the half-sent message
                withContext(NonCancellable) { client?.send(TdApi.DeleteMessages(job.chatId, longArrayOf(pending.id), true)) { } }
            }
        }
    }

    // ----- fetching again -----

    override suspend fun fetch(chatId: Long, botApiMessageId: Long): TdFetch {
        if (client == null) return TdFetch.Unavailable
        if (!knowChat(chatId)) return TdFetch.Unavailable
        return when (val r = call(TdApi.GetMessage(chatId, TdIds.toTdlib(botApiMessageId)))) {
            is TdApi.Message -> toSent(r)?.let { TdFetch.Found(it) } ?: TdFetch.NotFound
            is TdApi.Error -> if (r.code == 404 || r.message.contains("not found", true)) TdFetch.NotFound else TdFetch.Unavailable
            else -> TdFetch.Unavailable
        }
    }

    private fun fileOf(c: TdApi.MessageContent?): TdApi.File? = when (c) {
        is TdApi.MessageDocument -> c.document?.document
        is TdApi.MessageVideo -> c.video?.video
        is TdApi.MessagePhoto -> c.photo?.sizes?.maxByOrNull { it.width.toLong() * it.height }?.photo
        else -> null
    }

    /** A TDLib message as the Bot API form of what we sent (ids shifted back, sizes read from the content). */
    private fun toSent(m: TdApi.Message): SentMessage? {
        val thread = (m.topicId as? TdApi.MessageTopicForum)?.forumTopicId?.toLong()
        val id = TdIds.fromTdlib(m.id)
        return when (val c = m.content) {
            is TdApi.MessageDocument -> SentMessage(m.chatId, thread, id, c.document.document.remote?.uniqueId, c.document.document.size, null, null, null, SendAs.DOCUMENT)
            is TdApi.MessageVideo -> SentMessage(
                m.chatId, thread, id, c.video.video.remote?.uniqueId, c.video.video.size, c.video.width, c.video.height, c.video.duration * 1000L, SendAs.VIDEO,
            )
            is TdApi.MessagePhoto -> {
                val big = c.photo.sizes.maxByOrNull { it.width.toLong() * it.height } ?: return null
                SentMessage(m.chatId, thread, id, big.photo.remote?.uniqueId, big.photo.size.takeIf { it > 0 }, big.width, big.height, null, SendAs.PHOTO)
            }
            else -> null
        }
    }
}
