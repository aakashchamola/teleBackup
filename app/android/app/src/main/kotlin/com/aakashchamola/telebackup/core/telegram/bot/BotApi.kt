package com.aakashchamola.telebackup.core.telegram.bot

import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SentMessage
import com.aakashchamola.telebackup.core.telegram.TgError
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okio.BufferedSink
import okio.source
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

sealed class ApiResult<out T> {
    data class Ok<T>(val value: T) : ApiResult<T>()
    data class Err(val error: TgError) : ApiResult<Nothing>()
}

data class BotUser(val id: Long, val username: String, val name: String)
data class ChatSummary(val id: Long, val title: String, val type: String)
data class ChatInfo(val id: Long, val title: String, val isForum: Boolean)
data class MemberInfo(val status: String, val canManageTopics: Boolean)
data class TopicInfo(val threadId: Long, val name: String, val iconColor: Int?)

/**
 * Telegram Bot API over HTTPS (docs/TELEGRAM.md section 2). The token is read from [tokenProvider] at call time
 * and never logged: only the method name and the outcome are.
 */
class BotApi(
    private val tokenProvider: () -> String?,
    private val client: OkHttpClient = defaultClient(),
    private val baseUrl: String = "https://api.telegram.org",
) {
    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .build()

        /** Maps a Bot API failure to the error kind the upload loop acts on. */
        fun mapError(httpCode: Int, description: String, retryAfter: Long?, migrateTo: Long?): TgError = when {
            httpCode == 429 -> TgError.FloodWait(retryAfter ?: 5)
            httpCode == 413 -> TgError.TooLarge
            httpCode == 400 && migrateTo != null -> TgError.ChatMigrated(migrateTo)
            httpCode == 400 && description.contains("thread not found", true) -> TgError.TopicMissing
            httpCode == 400 && description.contains("TOPIC_DELETED", true) -> TgError.TopicMissing
            httpCode == 400 -> TgError.BadRequest(description)
            httpCode == 401 -> TgError.BadToken
            httpCode == 403 -> TgError.Forbidden(description)
            httpCode >= 500 -> TgError.Server(httpCode)
            else -> TgError.BadRequest(description.ifBlank { "HTTP $httpCode" })
        }
    }

    private val json = Json { ignoreUnknownKeys = true }

    // ----- setup calls -----

    suspend fun getMe(): ApiResult<BotUser> = objCall("getMe", FormBody.Builder().build()) { r ->
        BotUser(r.long("id") ?: 0, r.str("username") ?: "", r.str("first_name") ?: "")
    }

    /** Groups the bot has recently seen (updates are kept by Telegram for 24 hours). */
    suspend fun getUpdates(): ApiResult<List<ChatSummary>> =
        call("getUpdates", FormBody.Builder().add("timeout", "0").add("limit", "100").build()) { el ->
            val arr = el.jsonArray
            val seen = LinkedHashMap<Long, ChatSummary>()
            for (u in arr) {
                val o = u.jsonObject
                val chat = listOf("message", "my_chat_member", "edited_message", "channel_post")
                    .firstNotNullOfOrNull { o[it]?.jsonObject?.get("chat")?.jsonObject } ?: continue
                val type = chat.str("type") ?: continue
                if (type != "supergroup" && type != "group") continue
                val id = chat.long("id") ?: continue
                seen[id] = ChatSummary(id, chat.str("title") ?: "Group", type)
            }
            seen.values.toList()
        }

    suspend fun getChat(chatId: Long): ApiResult<ChatInfo> =
        objCall("getChat", FormBody.Builder().add("chat_id", chatId.toString()).build()) { r ->
            ChatInfo(r.long("id") ?: chatId, r.str("title") ?: "Group", r.bool("is_forum") ?: false)
        }

    suspend fun getChatMember(chatId: Long, userId: Long): ApiResult<MemberInfo> =
        objCall("getChatMember", FormBody.Builder().add("chat_id", chatId.toString()).add("user_id", userId.toString()).build()) { r ->
            MemberInfo(r.str("status") ?: "", r.bool("can_manage_topics") ?: false)
        }

    suspend fun sendMessage(chatId: Long, text: String, threadId: Long? = null): ApiResult<Long> {
        val b = FormBody.Builder().add("chat_id", chatId.toString()).add("text", text).add("disable_notification", "true")
        threadId?.let { b.add("message_thread_id", it.toString()) }
        return objCall("sendMessage", b.build()) { r -> r.long("message_id") ?: 0 }
    }

    suspend fun createForumTopic(chatId: Long, name: String): ApiResult<TopicInfo> =
        objCall("createForumTopic", FormBody.Builder().add("chat_id", chatId.toString()).add("name", name.take(128)).build()) { r ->
            TopicInfo(r.long("message_thread_id") ?: 0, r.str("name") ?: name, r.long("icon_color")?.toInt())
        }

    // ----- sending files -----

    suspend fun sendFile(job: SendJob, progress: (sent: Long, total: Long) -> Unit): ApiResult<SentMessage> {
        val file = File(job.path)
        if (!file.exists()) return ApiResult.Err(TgError.BadRequest("file is missing"))
        val (method, field) = when (job.sendAs) {
            SendAs.PHOTO -> "sendPhoto" to "photo"
            SendAs.VIDEO -> "sendVideo" to "video"
            SendAs.DOCUMENT -> "sendDocument" to "document"
        }
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("chat_id", job.chatId.toString())
            .addFormDataPart("caption", job.caption)
            .addFormDataPart("disable_notification", "true")
        job.threadId?.let { body.addFormDataPart("message_thread_id", it.toString()) }
        when (job.sendAs) {
            SendAs.VIDEO -> {
                body.addFormDataPart("supports_streaming", "true")
                job.width?.let { body.addFormDataPart("width", it.toString()) }
                job.height?.let { body.addFormDataPart("height", it.toString()) }
                job.durationMs?.let { body.addFormDataPart("duration", (it / 1000).toString()) }
            }
            SendAs.DOCUMENT -> body.addFormDataPart("disable_content_type_detection", "true")
            SendAs.PHOTO -> Unit
        }
        val media = (job.mimeType.ifBlank { "application/octet-stream" }).toMediaTypeOrNull()
        // The name goes in as given; OkHttp encodes non-ASCII names (RFC 5987) in the Content-Disposition header.
        body.addFormDataPart(field, job.displayName, ProgressFileBody(file, media, progress))
        return objCall(method, body.build()) { r -> parseSent(r, job.sendAs, job.chatId) }
    }

    private fun parseSent(m: JsonObject, kind: SendAs, fallbackChat: Long): SentMessage {
        val chat = m["chat"]?.jsonObject?.long("id") ?: fallbackChat
        val thread = if (m.bool("is_topic_message") == true) m.long("message_thread_id") else m.long("message_thread_id")
        var size: Long? = null; var w: Int? = null; var h: Int? = null; var dur: Long? = null; var uniq: String? = null
        when (kind) {
            SendAs.PHOTO -> m["photo"]?.jsonArray?.lastOrNull()?.jsonObject?.let {
                size = it.long("file_size"); w = it.long("width")?.toInt(); h = it.long("height")?.toInt(); uniq = it.str("file_unique_id")
            }
            SendAs.VIDEO -> m["video"]?.jsonObject?.let {
                size = it.long("file_size"); w = it.long("width")?.toInt(); h = it.long("height")?.toInt()
                dur = it.long("duration")?.times(1000); uniq = it.str("file_unique_id")
            }
            SendAs.DOCUMENT -> m["document"]?.jsonObject?.let { size = it.long("file_size"); uniq = it.str("file_unique_id") }
        }
        return SentMessage(chat, thread, m.long("message_id") ?: 0, uniq, size, w, h, dur, kind)
    }

    // ----- plumbing -----

    private suspend fun <T> objCall(method: String, body: RequestBody, parse: (JsonObject) -> T): ApiResult<T> =
        call(method, body) { el -> parse(el.jsonObject) }

    private suspend fun <T> call(method: String, body: RequestBody, parse: (JsonElement) -> T): ApiResult<T> =
        callRaw(method, body, parse)

    private suspend fun <T> callRaw(method: String, body: RequestBody, parse: (JsonElement) -> T): ApiResult<T> {
        val token = tokenProvider() ?: return ApiResult.Err(TgError.BadToken)
        val req = Request.Builder().url("$baseUrl/bot$token/$method").post(body).build()
        val call = client.newCall(req)
        val outcome: Result<Pair<Int, String>> = suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { if (cont.isActive) cont.resume(Result.failure(e)) }
                override fun onResponse(call: Call, response: Response) {
                    response.use { r ->
                        val text = try { r.body?.string() ?: "" } catch (e: IOException) { if (cont.isActive) cont.resume(Result.failure(e)); return }
                        if (cont.isActive) cont.resume(Result.success(r.code to text))
                    }
                }
            })
        }
        val (code, text) = outcome.getOrElse {
            Tlog.w("$method: network error ${it.javaClass.simpleName}")
            return ApiResult.Err(TgError.Network)
        }
        val root = try { json.parseToJsonElement(text).jsonObject } catch (e: Exception) {
            Tlog.w("$method: HTTP $code with unreadable reply")
            return ApiResult.Err(if (code >= 500) TgError.Server(code) else TgError.BadRequest("unreadable reply (HTTP $code)"))
        }
        if (root.bool("ok") == true) {
            Tlog.d("$method: ok")
            return ApiResult.Ok(parse(root["result"] ?: JsonNull))
        }
        val desc = root.str("description") ?: ""
        val params = root["parameters"]?.jsonObject
        val err = mapError(root.long("error_code")?.toInt() ?: code, desc, params?.long("retry_after"), params?.long("migrate_to_chat_id"))
        Tlog.w("$method: HTTP $code ${err::class.simpleName}")
        return ApiResult.Err(err)
    }

    private fun JsonObject.str(k: String) = this[k]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.long(k: String) = this[k]?.jsonPrimitive?.longOrNull
    private fun JsonObject.bool(k: String) = this[k]?.jsonPrimitive?.booleanOrNull
}

/** Streams a file from disk and reports how many bytes were written. */
class ProgressFileBody(
    private val file: File,
    private val type: MediaType?,
    private val onProgress: (Long, Long) -> Unit,
) : RequestBody() {
    override fun contentType() = type
    override fun contentLength() = file.length()
    override fun writeTo(sink: BufferedSink) {
        val total = file.length()
        var written = 0L
        file.source().use { src ->
            val buf = okio.Buffer()
            while (true) {
                val n = src.read(buf, 64 * 1024)
                if (n == -1L) break
                sink.write(buf, n)
                written += n
                onProgress(written, total)
            }
        }
    }
}
