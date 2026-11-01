package com.aakashchamola.telebackup.core.telegram.account

import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.AccountValue
import com.aakashchamola.telebackup.core.secrets.SecretNames
import com.aakashchamola.telebackup.core.secrets.Secrets
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.security.SecureRandom

/** What the login screens show. */
data class AccountSnapshot(
    val step: Step,
    val name: String? = null,
    val phoneMasked: String? = null,
    val codeSentTo: String? = null,
    val passwordHint: String? = null,
    val lastError: String? = null,
) {
    enum class Step { NONE, WAIT_PARAMS, WAIT_PHONE, WAIT_CODE, WAIT_PASSWORD, WAIT_OTHER, READY, EXPIRED }
}

/**
 * The account login and the one place that opens and closes the TDLib client.
 * It keeps `settings.accountState` true: READY while logged in, EXPIRED when a session that worked ended.
 * api id/hash and the database key live in the secret store, never in settings.
 */
class AccountAuth(
    private val gateway: TdGateway,
    private val settings: SettingsRepository,
    private val secrets: Secrets,
    private val folders: () -> Pair<File, File>,
    scope: CoroutineScope,
    private val settleMs: Long = 20_000,
    private val newKey: () -> String = ::randomKey,
) {
    @Volatile private var lastError: String? = null
    @Volatile private var opened = false

    init {
        scope.launch { gateway.auth.collect { onAuth(it) } }
    }

    private fun onAuth(a: TdAuth) {
        when (a) {
            is TdAuth.Ready -> {
                settings.accountState = AccountValue.READY
                settings.accountName = a.name
                lastError = null
            }
            TdAuth.LoggedOut -> {
                // a session that was READY and then ended needs a new login; a login that never finished stays NONE
                if (settings.accountState == AccountValue.READY) settings.accountState = AccountValue.EXPIRED
            }
            else -> Unit
        }
    }

    fun snapshot(): AccountSnapshot {
        val saved = settings.accountState
        return when (val a = gateway.auth.value) {
            TdAuth.WaitParams -> AccountSnapshot(AccountSnapshot.Step.WAIT_PARAMS, lastError = lastError)
            TdAuth.WaitPhone -> AccountSnapshot(
                if (saved == AccountValue.EXPIRED) AccountSnapshot.Step.EXPIRED else AccountSnapshot.Step.WAIT_PHONE,
                lastError = lastError,
            )
            is TdAuth.WaitCode -> AccountSnapshot(AccountSnapshot.Step.WAIT_CODE, codeSentTo = a.sentTo, lastError = lastError)
            is TdAuth.WaitPassword -> AccountSnapshot(AccountSnapshot.Step.WAIT_PASSWORD, passwordHint = a.hint, lastError = lastError)
            is TdAuth.WaitOther -> AccountSnapshot(AccountSnapshot.Step.WAIT_OTHER, lastError = lastError ?: a.what)
            is TdAuth.Ready -> AccountSnapshot(AccountSnapshot.Step.READY, name = a.name, phoneMasked = a.phoneMasked)
            TdAuth.Closed, TdAuth.LoggedOut -> when (saved) {
                AccountValue.READY -> AccountSnapshot(AccountSnapshot.Step.READY, name = settings.accountName)
                AccountValue.EXPIRED -> AccountSnapshot(AccountSnapshot.Step.EXPIRED, name = settings.accountName, lastError = lastError)
                AccountValue.NONE -> AccountSnapshot(AccountSnapshot.Step.NONE, lastError = lastError)
            }
        }
    }

    /** First step of the login: saves api id and hash, opens the client. Ends at WAIT_PHONE (or READY for a saved session). */
    suspend fun start(apiId: Long, apiHash: String): AccountSnapshot {
        val hash = apiHash.trim()
        if (apiId <= 0 || apiId > Int.MAX_VALUE || !Regex("[0-9a-fA-F]{32}").matches(hash)) {
            lastError = "That api_id or api_hash does not look right. Copy both again from my.telegram.org."
            return snapshot()
        }
        secrets.put(SecretNames.API_ID, apiId.toString())
        secrets.put(SecretNames.API_HASH, hash)
        lastError = null
        open()
        waitSettled()
        return snapshot()
    }

    private suspend fun open() {
        val id = secrets.get(SecretNames.API_ID)?.toIntOrNull()
        val hash = secrets.get(SecretNames.API_HASH)
        if (id == null || hash == null) { lastError = "Enter the api_id and api_hash first."; return }
        val key = secrets.get(SecretNames.TD_KEY) ?: newKey().also { secrets.put(SecretNames.TD_KEY, it) }
        val (db, files) = folders()
        gateway.open(TdParams(id, hash, db, files, key))
        opened = true
    }

    private suspend fun waitSettled(ms: Long = settleMs) {
        withTimeoutOrNull(ms) { gateway.auth.first { it !is TdAuth.Closed && it !is TdAuth.WaitParams } }
    }

    private suspend fun step(r: TdStep): AccountSnapshot {
        when (r) {
            TdStep.Ok -> lastError = null
            is TdStep.Rejected -> lastError = r.message
            TdStep.Network -> lastError = "No internet. Try again when online."
        }
        return snapshot()
    }

    suspend fun phone(phone: String): AccountSnapshot {
        val p = phone.trim().replace(" ", "").replace("-", "")
        if (!Regex("\\+?[0-9]{7,15}").matches(p)) {
            lastError = "Type the phone number with the country code, like +91 98765 43210."
            return snapshot()
        }
        return step(gateway.submitPhone(if (p.startsWith("+")) p else "+$p"))
    }

    suspend fun code(code: String): AccountSnapshot = step(gateway.submitCode(code.trim().replace(" ", "")))
    suspend fun password(password: String): AccountSnapshot = step(gateway.submitPassword(password))
    suspend fun resendCode(): AccountSnapshot = step(gateway.resendCode())

    /** Logs out on the Telegram side, wipes the local session and the stored keys. Uploads of big files wait again. */
    suspend fun logout() {
        runCatching { if (!opened) open(); gateway.logOut() }.onFailure { Tlog.w("logout: ${it.javaClass.simpleName}") }
        gateway.close(); opened = false
        secrets.remove(SecretNames.TD_KEY)
        settings.accountState = AccountValue.NONE
        settings.accountName = null
        lastError = null
    }

    /**
     * Makes sure the saved session is open and ready. NotLoggedIn when there is none or it was ended (the state
     * becomes EXPIRED); Offline when Telegram cannot be reached in time.
     */
    suspend fun ensureReady(): Readiness {
        if (settings.accountState == AccountValue.NONE) return Readiness.NotLoggedIn
        if (gateway.auth.value !is TdAuth.Ready) {
            if (!opened || gateway.auth.value is TdAuth.Closed) open()
            waitSettled()
        }
        return when (gateway.auth.value) {
            is TdAuth.Ready -> Readiness.Ready
            TdAuth.WaitPhone, TdAuth.LoggedOut, is TdAuth.WaitCode, is TdAuth.WaitPassword, is TdAuth.WaitOther -> {
                settings.accountState = AccountValue.EXPIRED
                Readiness.NotLoggedIn
            }
            else -> Readiness.Offline
        }
    }

    /** Stops the client when a run is over, so it does not sit in memory all day. The session stays on disk. */
    fun release() { gateway.close(); opened = false }

    enum class Readiness { Ready, NotLoggedIn, Offline }

    companion object {
        fun randomKey(): String {
            val b = ByteArray(32).also { SecureRandom().nextBytes(it) }
            return b.joinToString("") { "%02x".format(it) }
        }
    }
}
