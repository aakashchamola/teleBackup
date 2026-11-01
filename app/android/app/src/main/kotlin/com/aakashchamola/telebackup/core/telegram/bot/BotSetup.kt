package com.aakashchamola.telebackup.core.telegram.bot

import com.aakashchamola.telebackup.core.db.TopicEntity
import com.aakashchamola.telebackup.core.db.TopicStore
import com.aakashchamola.telebackup.core.model.TopicSource
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.time.Clock

/** Result of the three checks the setup screen shows for a group. */
data class GroupCheck(val chatId: Long, val title: String, val topicsOn: Boolean, val botIsAdmin: Boolean, val botCanManageTopics: Boolean) {
    val allGood get() = topicsOn && botIsAdmin && botCanManageTopics
}

/** Plain-word text for a Telegram error, safe to show on a setup screen. */
fun TgError.setupMessage(): String = when (this) {
    TgError.BadToken -> "That token did not work. Copy it again from BotFather."
    TgError.Network -> "No internet. Try again when online."
    is TgError.FloodWait -> "Telegram says wait $seconds seconds, then try again."
    is TgError.Forbidden -> "The bot is not allowed to do that in the group. Make it an admin."
    TgError.TopicMissing -> "That topic is gone in Telegram."
    else -> userMessage
}

/**
 * The calls behind the setup screens: check a token, find the group, check its rights, post the hello message, make topics.
 * The token is kept only in [token] until the caller has stored it in the SecretStore.
 */
class BotSetup(
    private val settings: SettingsRepository,
    private val topics: TopicStore,
    private val clock: Clock,
    private val storedToken: () -> String? = { null },
    private val apiFor: (tokenProvider: () -> String?) -> BotApi,
) {
    @Volatile private var token: String? = null
    private val api get() = apiFor { token ?: storedToken() }

    /** Checks the token with getMe. On success remembers it for the next calls and saves the bot's name. */
    suspend fun checkToken(candidate: String): ApiResult<BotUser> {
        token = candidate.trim()
        val r = api.getMe()
        if (r is ApiResult.Ok) {
            settings.botId = r.value.id
            settings.botUsername = r.value.username
        } else token = null
        return r
    }

    fun tokenInUse(): String? = token

    suspend fun findGroups(): ApiResult<List<ChatSummary>> = api.getUpdates()

    suspend fun checkGroup(chatId: Long): ApiResult<GroupCheck> {
        val botId = settings.botId ?: return ApiResult.Err(TgError.BadToken)
        var id = chatId
        var chat = api.getChat(id)
        if (chat is ApiResult.Err && chat.error is TgError.ChatMigrated) {
            id = (chat.error as TgError.ChatMigrated).newChatId
            chat = api.getChat(id)
        }
        val info = (chat as? ApiResult.Ok)?.value ?: return ApiResult.Err((chat as ApiResult.Err).error)
        val member = api.getChatMember(info.id, botId)
        val m = (member as? ApiResult.Ok)?.value ?: MemberInfo("", false)
        val admin = m.status == "administrator" || m.status == "creator"
        return ApiResult.Ok(GroupCheck(info.id, info.title, info.isForum, admin, admin && m.canManageTopics))
    }

    /** Saves the group and posts the hello message in its General topic. */
    suspend fun selectGroup(check: GroupCheck): ApiResult<Long> {
        val hello = api.sendMessage(check.chatId, "teleBackup is connected. Each folder you back up gets its own topic here.")
        if (hello is ApiResult.Ok) {
            settings.chatId = check.chatId
            settings.chatTitle = check.title
        }
        return hello
    }

    /** Makes a topic in the saved group and remembers it (a bot cannot list topics later). */
    suspend fun createTopic(name: String): ApiResult<TopicEntity> {
        val chat = settings.chatId ?: return ApiResult.Err(TgError.Forbidden("no group chosen"))
        return when (val r = api.createForumTopic(chat, name)) {
            is ApiResult.Ok -> {
                val t = TopicEntity(r.value.threadId, chat, r.value.name, r.value.iconColor, TopicSource.CREATED_BY_APP, false, clock.now())
                topics.upsert(t)
                ApiResult.Ok(t)
            }
            is ApiResult.Err -> {
                val e = r.error
                if (e is TgError.ChatMigrated) { settings.chatId = e.newChatId; createTopic(name) } else r
            }
        }
    }
}
