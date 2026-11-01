package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.model.AccountCheck
import com.aakashchamola.telebackup.core.model.AccountValue
import com.aakashchamola.telebackup.core.model.FileKind
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.secrets.SecretNames
import com.aakashchamola.telebackup.core.secrets.Secrets
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.SentMessage
import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.telegram.account.*
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.io.File

class MemSecrets : Secrets {
    val map = HashMap<String, String>()
    override fun put(name: String, value: String) { map[name] = value }
    override fun get(name: String): String? = map[name]
    override fun remove(name: String) { map.remove(name) }
    override fun clearAll() = map.clear()
}

/** Acts like TDLib: a saved session opens straight to Ready, a new one asks for phone, code, maybe password. */
class FakeGateway(var hasSession: Boolean = false, var needsPassword: Boolean = false) : TdGateway {
    private val state = MutableStateFlow<TdAuth>(TdAuth.Closed)
    override val auth: StateFlow<TdAuth> get() = state
    var params: TdParams? = null
    val sent = ArrayList<SendJob>()
    var sendResult: SendResult? = null
    var fetchResult: TdFetch = TdFetch.NotFound
    var closes = 0
    var loggedOut = false
    var goodCode = "12345"; var goodPassword = "pw"
    var opensOffline = false

    override suspend fun open(params: TdParams) {
        this.params = params
        state.value = when {
            opensOffline -> TdAuth.WaitParams
            hasSession -> TdAuth.Ready("Aakash C", "+91 ••••• ••210")
            else -> TdAuth.WaitPhone
        }
    }
    override suspend fun submitPhone(phone: String): TdStep { state.value = TdAuth.WaitCode("Telegram app"); return TdStep.Ok }
    override suspend fun submitCode(code: String): TdStep {
        if (code != goodCode) return TdStep.Rejected("That code is not right.")
        state.value = if (needsPassword) TdAuth.WaitPassword("pet name") else TdAuth.Ready("Aakash C", "+91 ••••• ••210")
        return TdStep.Ok
    }
    override suspend fun submitPassword(password: String): TdStep {
        if (password != goodPassword) return TdStep.Rejected("That password is not right.")
        state.value = TdAuth.Ready("Aakash C", "+91 ••••• ••210"); return TdStep.Ok
    }
    override suspend fun resendCode(): TdStep = TdStep.Ok
    override suspend fun send(job: SendJob, progress: (Long, Long) -> Unit): SendResult {
        sent += job
        return sendResult ?: SendResult.Sent(SentMessage(job.chatId, job.threadId, 900, "uq", job.sizeBytes, null, null, null, job.sendAs))
    }
    override suspend fun fetch(chatId: Long, botApiMessageId: Long): TdFetch = fetchResult
    override suspend fun logOut() { loggedOut = true; state.value = TdAuth.LoggedOut }
    override fun close() { closes++; if (state.value is TdAuth.Ready) state.value = TdAuth.Closed }
    fun sessionEnded() { state.value = TdAuth.LoggedOut }
}

class AccountTest {
    private val hash = "0123456789abcdef0123456789abcdef"

    private class Rig(val gw: FakeGateway = FakeGateway()) {
        val w = World()
        val secrets = MemSecrets()
        val auth = AccountAuth(gw, w.settings, secrets, { File("db") to File("files") }, CoroutineScope(Dispatchers.Unconfined), settleMs = 100) { "key-1" }
    }

    @Test fun fullLoginWithPassword() = runBlocking<Unit> {
        val r = Rig(FakeGateway(needsPassword = true))
        assertThat(r.auth.snapshot().step).isEqualTo(AccountSnapshot.Step.NONE)
        assertThat(r.auth.start(12345, hash).step).isEqualTo(AccountSnapshot.Step.WAIT_PHONE)
        assertThat(r.auth.phone("+91 98765-43210").step).isEqualTo(AccountSnapshot.Step.WAIT_CODE)
        assertThat(r.auth.snapshot().codeSentTo).isEqualTo("Telegram app")
        val bad = r.auth.code("00000")
        assertThat(bad.lastError).contains("not right"); assertThat(bad.step).isEqualTo(AccountSnapshot.Step.WAIT_CODE)
        assertThat(r.auth.code("123 45").step).isEqualTo(AccountSnapshot.Step.WAIT_PASSWORD)
        assertThat(r.auth.snapshot().passwordHint).isEqualTo("pet name")
        val done = r.auth.password("pw")
        assertThat(done.step).isEqualTo(AccountSnapshot.Step.READY)
        assertThat(done.name).isEqualTo("Aakash C")
        assertThat(r.w.settings.accountState).isEqualTo(AccountValue.READY)
        assertThat(r.w.settings.accountName).isEqualTo("Aakash C")
    }

    @Test fun apiIdAndHashAreCheckedKeptSecretAndKeyIsMade() = runBlocking<Unit> {
        val r = Rig()
        assertThat(r.auth.start(0, hash).lastError).contains("api_id")
        assertThat(r.auth.start(12345, "short").lastError).contains("api_hash")
        assertThat(r.gw.params).isNull()
        r.auth.start(12345, " $hash ")
        assertThat(r.secrets.get(SecretNames.API_ID)).isEqualTo("12345")
        assertThat(r.secrets.get(SecretNames.API_HASH)).isEqualTo(hash)
        assertThat(r.secrets.get(SecretNames.TD_KEY)).isEqualTo("key-1")
        assertThat(r.gw.params!!.databaseKey).isEqualTo("key-1")
        // nothing secret in plain settings
        assertThat(r.w.kv.all().values.joinToString()).doesNotContain(hash)
    }

    @Test fun phoneNumberIsCheckedAndGetsAPlus() = runBlocking<Unit> {
        val r = Rig(); r.auth.start(1, hash)
        assertThat(r.auth.phone("12ab").lastError).contains("country code")
        assertThat(r.auth.phone("919876543210").step).isEqualTo(AccountSnapshot.Step.WAIT_CODE)
    }

    @Test fun savedSessionReopensWithoutAnyCode() = runBlocking<Unit> {
        val r = Rig(FakeGateway(hasSession = true))
        r.w.settings.accountState = AccountValue.READY
        r.secrets.put(SecretNames.API_ID, "1"); r.secrets.put(SecretNames.API_HASH, hash)
        assertThat(r.auth.ensureReady()).isEqualTo(AccountAuth.Readiness.Ready)
        r.auth.release()
        assertThat(r.gw.closes).isEqualTo(1)
        assertThat(r.auth.ensureReady()).isEqualTo(AccountAuth.Readiness.Ready)   // opened again
    }

    @Test fun noLoginMeansNotLoggedInAndNothingOpens() = runBlocking<Unit> {
        val r = Rig()
        assertThat(r.auth.ensureReady()).isEqualTo(AccountAuth.Readiness.NotLoggedIn)
        assertThat(r.gw.params).isNull()
    }

    @Test fun aSessionThatTelegramEndedBecomesExpired() = runBlocking<Unit> {
        val r = Rig(FakeGateway(hasSession = true))
        r.auth.start(1, hash)
        assertThat(r.w.settings.accountState).isEqualTo(AccountValue.READY)
        r.gw.sessionEnded()
        assertThat(r.w.settings.accountState).isEqualTo(AccountValue.EXPIRED)
        assertThat(r.auth.snapshot().step).isEqualTo(AccountSnapshot.Step.EXPIRED)
    }

    @Test fun reopenAfterRevokedSessionIsExpiredNotReady() = runBlocking<Unit> {
        val gw = FakeGateway(hasSession = false)   // the database no longer holds a session
        val r = Rig(gw)
        r.w.settings.accountState = AccountValue.READY
        r.secrets.put(SecretNames.API_ID, "1"); r.secrets.put(SecretNames.API_HASH, hash)
        assertThat(r.auth.ensureReady()).isEqualTo(AccountAuth.Readiness.NotLoggedIn)
        assertThat(r.w.settings.accountState).isEqualTo(AccountValue.EXPIRED)
    }

    @Test fun cannotReachTelegramIsOfflineNotLoggedOut() = runBlocking<Unit> {
        val gw = FakeGateway(hasSession = true).also { it.opensOffline = true }   // stays at WaitParams, as TDLib does with no network at first
        val r = Rig(gw)
        r.w.settings.accountState = AccountValue.READY
        r.secrets.put(SecretNames.API_ID, "1"); r.secrets.put(SecretNames.API_HASH, hash)
        assertThat(r.auth.ensureReady()).isEqualTo(AccountAuth.Readiness.Offline)
        assertThat(r.w.settings.accountState).isEqualTo(AccountValue.READY)   // not logged out just because we are offline
    }

    @Test fun logoutWipesKeysAndState() = runBlocking<Unit> {
        val r = Rig(FakeGateway(hasSession = true))
        r.auth.start(1, hash)
        r.auth.logout()
        assertThat(r.gw.loggedOut).isTrue()
        assertThat(r.secrets.get(SecretNames.TD_KEY)).isNull()
        assertThat(r.w.settings.accountState).isEqualTo(AccountValue.NONE)
        assertThat(r.w.settings.accountName).isNull()
        assertThat(r.auth.snapshot().step).isEqualTo(AccountSnapshot.Step.NONE)
    }

    @Test fun senderSendsWhenReadyAndRefusesWhenNot() = runBlocking<Unit> {
        val r = Rig(FakeGateway(hasSession = true))
        val sender = AccountSender(r.auth, r.gw)
        val job = SendJob(-1001, 5, "/x/big.mp4", "big.mp4", "video/mp4", SendAs.DOCUMENT, "c", 80_000_000)
        assertThat(sender.send(job) { _, _ -> }).isInstanceOf(SendResult.Failed::class.java)   // not logged in yet
        assertThat(r.gw.sent).isEmpty()
        r.auth.start(1, hash)
        val ok = sender.send(job) { _, _ -> } as SendResult.Sent
        assertThat(ok.message.size).isEqualTo(80_000_000)
        r.gw.sendResult = SendResult.Failed(TgError.FloodWait(30))
        assertThat((sender.send(job) { _, _ -> } as SendResult.Failed).error).isEqualTo(TgError.FloodWait(30))
        // a session that ended maps to AccountLoggedOut so the upload loop stops the account route
        r.gw.sessionEnded()
        r.gw.hasSession = false
        r.auth.release()
        assertThat((sender.send(job) { _, _ -> } as SendResult.Failed).error).isEqualTo(TgError.AccountLoggedOut)
    }

    private fun verified(size: Long = 80_000_000, sendAs: SendAs = SendAs.DOCUMENT) =
        Fx.file(state = com.aakashchamola.telebackup.core.model.FileState.VERIFIED, kind = FileKind.VIDEO).copy(
            sendAs = sendAs, tgSize = size, tgFileUniqueId = "uq", tgChatId = -1001, tgMessageId = 900,
        )

    @Test fun recheckAnswers() = runBlocking<Unit> {
        val r = Rig(FakeGateway(hasSession = true))
        val v = AccountRecheck(r.auth, r.gw)
        assertThat(v.recheck(verified())).isEqualTo(AccountCheck.NOT_READY)   // never logged in on this install
        r.auth.start(1, hash)
        fun found(size: Long? = 80_000_000, kind: SendAs = SendAs.DOCUMENT, uq: String? = "uq") =
            TdFetch.Found(SentMessage(-1001, 5, 900, uq, size, null, null, null, kind))
        r.gw.fetchResult = found(); assertThat(v.recheck(verified())).isEqualTo(AccountCheck.OK)
        r.gw.fetchResult = found(size = 79_999_999); assertThat(v.recheck(verified())).isEqualTo(AccountCheck.MISMATCH)
        r.gw.fetchResult = found(uq = "other"); assertThat(v.recheck(verified())).isEqualTo(AccountCheck.MISMATCH)
        r.gw.fetchResult = found(kind = SendAs.PHOTO); assertThat(v.recheck(verified())).isEqualTo(AccountCheck.MISMATCH)
        r.gw.fetchResult = TdFetch.NotFound; assertThat(v.recheck(verified())).isEqualTo(AccountCheck.NOT_FOUND)
        r.gw.fetchResult = TdFetch.Unavailable; assertThat(v.recheck(verified())).isEqualTo(AccountCheck.UNAVAILABLE)
        // a file with no recorded message can never pass
        assertThat(v.recheck(verified().copy(tgMessageId = null))).isEqualTo(AccountCheck.NOT_FOUND)
        // a photo's byte size is not compared (Telegram re-encodes it), its file id is
        val photo = verified(size = 2_000_000, sendAs = SendAs.PHOTO)
        r.gw.fetchResult = found(size = 785_596, kind = SendAs.PHOTO); assertThat(v.recheck(photo)).isEqualTo(AccountCheck.OK)
        // a recorded size of null never passes for a document
        r.gw.fetchResult = found(); assertThat(v.recheck(verified().copy(tgSize = null))).isEqualTo(AccountCheck.MISMATCH)
    }
}
