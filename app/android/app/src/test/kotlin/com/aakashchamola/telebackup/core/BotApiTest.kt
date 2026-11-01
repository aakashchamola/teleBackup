package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.telegram.bot.*
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File

class BotApiTest {
    private val token = "123456789:AAH-abcdefghijklmnopqrstuvwxyz0123456"
    private lateinit var server: MockWebServer
    private lateinit var api: BotApi
    private val tmp = File.createTempFile("tbtest", ".bin").also { it.writeBytes(ByteArray(300_000) { i -> i.toByte() }); it.deleteOnExit() }

    @Before fun up() {
        server = MockWebServer().also { it.start() }
        api = BotApi({ token }, baseUrl = server.url("/").toString().trimEnd('/'))
    }
    @After fun down() { runCatching { server.shutdown() } }

    private fun ok(result: String) = MockResponse().setBody("""{"ok":true,"result":$result}""")
    private fun fail(code: Int, desc: String, params: String = "") =
        MockResponse().setResponseCode(code).setBody("""{"ok":false,"error_code":$code,"description":"$desc"${if (params.isNotEmpty()) ""","parameters":$params""" else ""}}""")

    private fun job(sendAs: SendAs, name: String = "IMG_1.jpg", thread: Long? = 5) = SendJob(
        -1001L, thread, tmp.absolutePath, name, "image/jpeg", sendAs, "cap\n#tb abc", tmp.length(), 4000, 3000, 61_500,
    )

    @Test fun getMeParses() = runBlocking<Unit> {
        server.enqueue(ok("""{"id":42,"username":"fam_bot","first_name":"Family"}"""))
        val r = api.getMe() as ApiResult.Ok
        assertThat(r.value).isEqualTo(BotUser(42, "fam_bot", "Family"))
        assertThat(server.takeRequest().path).isEqualTo("/bot$token/getMe")
    }

    @Test fun everyErrorRowMapsToItsKind() = runBlocking<Unit> {
        val cases = listOf(
            fail(429, "Too Many Requests", """{"retry_after":7}""") to TgError.FloodWait(7),
            fail(413, "Request Entity Too Large") to TgError.TooLarge,
            fail(400, "Bad Request: message thread not found") to TgError.TopicMissing,
            fail(400, "Bad Request: group chat was upgraded", """{"migrate_to_chat_id":-1009}""") to TgError.ChatMigrated(-1009),
            fail(400, "Bad Request: wrong file type") to TgError.BadRequest("Bad Request: wrong file type"),
            fail(401, "Unauthorized") to TgError.BadToken,
            fail(403, "Forbidden: bot was kicked from the supergroup chat") to TgError.Forbidden("Forbidden: bot was kicked from the supergroup chat"),
            fail(502, "Bad Gateway") to TgError.Server(502),
        )
        for ((resp, expected) in cases) {
            server.enqueue(resp)
            val r = api.getMe()
            assertThat((r as ApiResult.Err).error).isEqualTo(expected)
        }
    }

    @Test fun unreadableReplyIsAServerOrBadRequestError() = runBlocking<Unit> {
        server.enqueue(MockResponse().setResponseCode(200).setBody("<html>"))
        assertThat((api.getMe() as ApiResult.Err).error).isInstanceOf(TgError.BadRequest::class.java)
        server.enqueue(MockResponse().setResponseCode(503).setBody("oops"))
        assertThat((api.getMe() as ApiResult.Err).error).isInstanceOf(TgError.Server::class.java)
    }

    @Test fun droppedConnectionIsANetworkError() = runBlocking<Unit> {
        server.shutdown()
        assertThat((api.getMe() as ApiResult.Err).error).isEqualTo(TgError.Network)
    }

    @Test fun noTokenIsABadToken() = runBlocking<Unit> {
        val none = BotApi({ null }, baseUrl = server.url("/").toString().trimEnd('/'))
        assertThat((none.getMe() as ApiResult.Err).error).isEqualTo(TgError.BadToken)
    }

    @Test fun photoRequestShapeAndReply() = runBlocking<Unit> {
        server.enqueue(ok("""{"message_id":900,"message_thread_id":5,"chat":{"id":-1001},"photo":[{"file_id":"a","file_unique_id":"s","width":90,"height":67,"file_size":2000},{"file_id":"b","file_unique_id":"L","width":1280,"height":960,"file_size":180000}]}"""))
        val progress = ArrayList<Pair<Long, Long>>()
        val r = api.sendFile(job(SendAs.PHOTO)) { s, t -> progress += s to t } as ApiResult.Ok
        val req = server.takeRequest()
        val body = req.body.readUtf8()
        assertThat(req.path).isEqualTo("/bot$token/sendPhoto")
        assertThat(req.getHeader("Content-Type")).startsWith("multipart/form-data")
        assertThat(body).contains("name=\"chat_id\"").also { assertThat(body).contains("-1001") }
        assertThat(body).contains("name=\"message_thread_id\"")
        assertThat(body).contains("name=\"disable_notification\"")
        assertThat(body).contains("name=\"caption\"")
        assertThat(body).contains("#tb abc")
        assertThat(body).contains("name=\"photo\"; filename=\"IMG_1.jpg\"")
        assertThat(r.value.size).isEqualTo(180000)           // the largest size is the last one
        assertThat(r.value.width).isEqualTo(1280)
        assertThat(r.value.threadId).isEqualTo(5)
        assertThat(r.value.messageId).isEqualTo(900)
        assertThat(progress.last()).isEqualTo(tmp.length() to tmp.length())
    }

    @Test fun videoRequestCarriesStreamingAndDurationInSeconds() = runBlocking<Unit> {
        server.enqueue(ok("""{"message_id":901,"message_thread_id":5,"chat":{"id":-1001},"video":{"file_unique_id":"v","width":1920,"height":1080,"duration":61,"file_size":300000}}"""))
        val r = api.sendFile(job(SendAs.VIDEO, "VID.mp4")) { _, _ -> } as ApiResult.Ok
        val body = server.takeRequest().body.readUtf8()
        assertThat(body).contains("name=\"supports_streaming\"")
        assertThat(body).contains("name=\"duration\"")
        assertThat(body).contains("61")
        assertThat(body).contains("name=\"video\"; filename=\"VID.mp4\"")
        assertThat(r.value.durationMs).isEqualTo(61_000)
        assertThat(r.value.size).isEqualTo(300000)
    }

    @Test fun documentRequestKeepsTheExactBytes() = runBlocking<Unit> {
        server.enqueue(ok("""{"message_id":902,"chat":{"id":-1001},"document":{"file_unique_id":"d","file_size":300000,"file_name":"x.jpg"}}"""))
        val r = api.sendFile(job(SendAs.DOCUMENT, thread = null)) { _, _ -> } as ApiResult.Ok
        val req = server.takeRequest()
        val text = req.body.readUtf8()
        assertThat(text).contains("name=\"disable_content_type_detection\"")
        assertThat(text).doesNotContain("name=\"message_thread_id\"")   // General topic: no thread
        assertThat(r.value.size).isEqualTo(tmp.length())
        assertThat(r.value.threadId).isNull()
    }

    @Test fun bodyContainsEveryByteOfTheFile() = runBlocking<Unit> {
        server.enqueue(ok("""{"message_id":1,"chat":{"id":-1001},"document":{"file_size":300000}}"""))
        api.sendFile(job(SendAs.DOCUMENT)) { _, _ -> }
        val bytes = server.takeRequest().body.readByteArray()
        val needle = tmp.readBytes()
        var found = false
        outer@ for (i in 0..bytes.size - needle.size) {
            if (bytes[i] != needle[0]) continue
            for (j in needle.indices step 997) if (bytes[i + j] != needle[j]) continue@outer
            found = true; break
        }
        assertThat(found).isTrue()
    }

    @Test fun unicodeFileNameIsSentAsUtf8() = runBlocking<Unit> {
        server.enqueue(ok("""{"message_id":1,"chat":{"id":-1001},"document":{"file_size":300000}}"""))
        api.sendFile(job(SendAs.DOCUMENT, "ünïcödé name & spaces (1).jpg")) { _, _ -> }
        assertThat(server.takeRequest().body.readUtf8()).contains("ünïcödé name & spaces (1).jpg")
    }

    @Test fun missingFileIsRefusedWithoutACall() = runBlocking<Unit> {
        val r = api.sendFile(job(SendAs.DOCUMENT).copy(path = "/nope/missing.jpg")) { _, _ -> }
        assertThat((r as ApiResult.Err).error).isInstanceOf(TgError.BadRequest::class.java)
        assertThat(server.requestCount).isEqualTo(0)
    }

    @Test fun theTokenNeverReachesTheLog() = runBlocking<Unit> {
        val lines = ArrayList<String>()
        Tlog.sink = { _, l -> lines += l }
        server.enqueue(ok("""{"id":1,"username":"b","first_name":"B"}"""))
        server.enqueue(fail(401, "Unauthorized"))
        server.enqueue(fail(429, "Too Many Requests", """{"retry_after":3}"""))
        api.getMe(); api.getMe(); api.getMe()
        Tlog.sink = null
        assertThat(lines).isNotEmpty()
        assertThat(lines.joinToString("\n")).doesNotContain(token)
        assertThat(lines.joinToString("\n")).doesNotContain("AAH-")
    }

    @Test fun getUpdatesFindsGroups() = runBlocking<Unit> {
        server.enqueue(ok("""[{"update_id":1,"my_chat_member":{"chat":{"id":-1001,"title":"My photos backup","type":"supergroup"}}},
            {"update_id":2,"message":{"chat":{"id":55,"type":"private"}}},
            {"update_id":3,"message":{"chat":{"id":-1001,"title":"My photos backup","type":"supergroup"}}}]"""))
        val r = api.getUpdates() as ApiResult.Ok
        assertThat(r.value).containsExactly(ChatSummary(-1001, "My photos backup", "supergroup"))
    }

    @Test fun getUpdatesDropsTheOldBasicGroupAfterTopicsWereTurnedOn() = runBlocking<Unit> {
        // what a real phone sent: the basic group, then the supergroup it became (same title, new id)
        server.enqueue(ok("""[{"update_id":1,"message":{"chat":{"id":-5589,"title":"teleBackup TEST","type":"group"}}},
            {"update_id":2,"message":{"chat":{"id":-1003949,"title":"teleBackup TEST","type":"supergroup"}}},
            {"update_id":3,"my_chat_member":{"chat":{"id":-1003949,"title":"teleBackup TEST","type":"supergroup"}}}]"""))
        assertThat((api.getUpdates() as ApiResult.Ok).value).containsExactly(ChatSummary(-1003949, "teleBackup TEST", "supergroup"))
        // and when Telegram says so outright, even if the titles differ
        server.enqueue(ok("""[{"update_id":1,"message":{"chat":{"id":-77,"title":"Old name","type":"group"},"migrate_to_chat_id":-1008}},
            {"update_id":2,"message":{"chat":{"id":-1008,"title":"New name","type":"supergroup"}}}]"""))
        assertThat((api.getUpdates() as ApiResult.Ok).value).containsExactly(ChatSummary(-1008, "New name", "supergroup"))
    }

    @Test fun createForumTopicParses() = runBlocking<Unit> {
        server.enqueue(ok("""{"message_thread_id":77,"name":"Screenshots","icon_color":7322096}"""))
        val r = api.createForumTopic(-1001, "Screenshots") as ApiResult.Ok
        assertThat(r.value).isEqualTo(TopicInfo(77, "Screenshots", 7322096))
    }

    // ----- BotSetup on top of the API -----

    private fun setup(w: World) = BotSetup(w.settings, w.topics, w.clock) { tp -> BotApi(tp, baseUrl = server.url("/").toString().trimEnd('/')) }

    @Test fun setupChecksTokenGroupAndRights() = runBlocking<Unit> {
        val w = World()
        val s = setup(w)
        server.enqueue(ok("""{"id":42,"username":"fam_bot","first_name":"Family"}"""))
        assertThat((s.checkToken(" $token ") as ApiResult.Ok).value.id).isEqualTo(42)
        assertThat(w.settings.botUsername).isEqualTo("fam_bot")
        assertThat(s.tokenInUse()).isEqualTo(token)
        server.enqueue(ok("""{"id":-1001,"title":"My photos backup","type":"supergroup","is_forum":true}"""))
        server.enqueue(ok("""{"status":"administrator","can_manage_topics":true}"""))
        val check = (s.checkGroup(-1001) as ApiResult.Ok).value
        assertThat(check.allGood).isTrue()
        server.enqueue(ok("""{"message_id":3}"""))
        assertThat(s.selectGroup(check)).isInstanceOf(ApiResult.Ok::class.java)
        assertThat(w.settings.chatId).isEqualTo(-1001)
        assertThat(w.settings.chatTitle).isEqualTo("My photos backup")
    }

    @Test fun setupReportsEachMissingRight() = runBlocking<Unit> {
        val w = World(); val s = setup(w)
        server.enqueue(ok("""{"id":42,"username":"b","first_name":"B"}""")); s.checkToken(token)
        server.enqueue(ok("""{"id":-1001,"title":"G","is_forum":false}"""))
        server.enqueue(ok("""{"status":"member"}"""))
        val c = (s.checkGroup(-1001) as ApiResult.Ok).value
        assertThat(c.topicsOn).isFalse(); assertThat(c.botIsAdmin).isFalse(); assertThat(c.botCanManageTopics).isFalse()
        server.enqueue(ok("""{"id":-1001,"title":"G","is_forum":true}"""))
        server.enqueue(ok("""{"status":"administrator","can_manage_topics":false}"""))
        val c2 = (s.checkGroup(-1001) as ApiResult.Ok).value
        assertThat(c2.botIsAdmin).isTrue(); assertThat(c2.botCanManageTopics).isFalse(); assertThat(c2.allGood).isFalse()
    }

    @Test fun wrongTokenIsForgotten() = runBlocking<Unit> {
        val w = World(); val s = setup(w)
        server.enqueue(fail(401, "Unauthorized"))
        assertThat(s.checkToken("nope")).isInstanceOf(ApiResult.Err::class.java)
        assertThat(s.tokenInUse()).isNull()
        assertThat(TgError.BadToken.setupMessage()).isEqualTo("That token did not work. Copy it again from BotFather.")
    }

    @Test fun setupFollowsAGroupThatBecameASupergroup() = runBlocking<Unit> {
        val w = World(); val s = setup(w)
        server.enqueue(ok("""{"id":42,"username":"b","first_name":"B"}""")); s.checkToken(token)
        server.enqueue(fail(400, "Bad Request: group chat was upgraded to a supergroup chat", """{"migrate_to_chat_id":-1009}"""))
        server.enqueue(ok("""{"id":-1009,"title":"G","is_forum":true}"""))
        server.enqueue(ok("""{"status":"administrator","can_manage_topics":true}"""))
        val c = (s.checkGroup(-55) as ApiResult.Ok).value
        assertThat(c.chatId).isEqualTo(-1009)
    }

    @Test fun createTopicRemembersItAndFollowsAMigration() = runBlocking<Unit> {
        val w = World(); val s = setup(w)
        server.enqueue(ok("""{"id":42,"username":"b","first_name":"B"}""")); s.checkToken(token)
        w.settings.chatId = -55
        server.enqueue(fail(400, "Bad Request: group chat was upgraded", """{"migrate_to_chat_id":-1009}"""))
        server.enqueue(ok("""{"message_thread_id":77,"name":"Screenshots","icon_color":1}"""))
        val t = (s.createTopic("Screenshots") as ApiResult.Ok).value
        assertThat(t.threadId).isEqualTo(77)
        assertThat(w.settings.chatId).isEqualTo(-1009)
        assertThat(w.topics.get(77)!!.chatId).isEqualTo(-1009)
    }
}
