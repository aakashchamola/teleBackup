package com.aakashchamola.telebackup.core.settings

import com.aakashchamola.telebackup.core.db.KeyValueStore
import com.aakashchamola.telebackup.core.model.AccountValue
import com.aakashchamola.telebackup.core.model.ControlValue

/** Typed access to the settings table. Defaults live here, not in the table (docs/DATA_MODEL.md "settings"). */
class SettingsRepository(private val kv: KeyValueStore) {

    object Keys {
        const val SETUP_DONE_AT = "app.setupDoneAt"
        const val SETUP_STEP = "app.setupStep"
        const val ALLOW_MOBILE = "network.allowMobileData"
        const val MOBILE_ONCE = "network.mobileOnceUntilEmpty"
        const val CONTROL_STATE = "control.state"
        const val DELAYED_UNTIL = "control.delayedUntil"
        const val DELAY_OPTIONS = "control.delayOptionsMinutes"
        const val DEFAULT_RETENTION = "rules.defaultRetentionDays"
        const val BOT_PACE = "upload.botPacePerMinute"
        const val ACCOUNT_GAP = "upload.accountMinGapSeconds"
        const val MAX_ATTEMPTS = "upload.maxAttempts"
        const val BOT_MAX_BYTES = "upload.botMaxBytes"
        const val BOT_PHOTO_MAX = "upload.botPhotoMaxBytes"
        const val BOT_ID = "telegram.botId"
        const val BOT_USERNAME = "telegram.botUsername"
        const val CHAT_ID = "telegram.chatId"
        const val CHAT_TITLE = "telegram.chatTitle"
        const val ACCOUNT_STATE = "account.state"
        const val ACCOUNT_NAME = "account.displayName"
        const val DELETES_BLOCKED = "deletes.blockedReason"
        const val ALLOW_BOT_ONLY_DELETE = "delete.allowBotOnly"
        const val LAST_SCAN = "stats.lastScanAt"
        const val LAST_UPLOAD = "stats.lastUploadAt"
        const val LAST_CLEAN = "stats.lastCleanAt"
        const val LAST_STOP_REASON = "stats.lastRunStopReason"
        const val TIME_WARP = "debug.timeWarp"
    }

    private fun long(key: String): Long? = kv.get(key)?.toLongOrNull()
    private fun bool(key: String, def: Boolean): Boolean = kv.get(key)?.let { it == "true" } ?: def
    private fun int(key: String, def: Int): Int = kv.get(key)?.toIntOrNull() ?: def
    private fun put(key: String, v: Any?) = kv.put(key, v?.toString())

    var setupDoneAt: Long? get() = long(Keys.SETUP_DONE_AT); set(v) = put(Keys.SETUP_DONE_AT, v)
    var setupStep: String get() = kv.get(Keys.SETUP_STEP) ?: "O1"; set(v) = put(Keys.SETUP_STEP, v)
    val setupDone: Boolean get() = setupDoneAt != null

    var allowMobileData: Boolean get() = bool(Keys.ALLOW_MOBILE, false); set(v) = put(Keys.ALLOW_MOBILE, v)
    var mobileOnceUntilEmpty: Boolean get() = bool(Keys.MOBILE_ONCE, false); set(v) = put(Keys.MOBILE_ONCE, v)

    var controlState: ControlValue
        get() = kv.get(Keys.CONTROL_STATE)?.let { runCatching { ControlValue.valueOf(it) }.getOrNull() } ?: ControlValue.RUNNING
        set(v) = put(Keys.CONTROL_STATE, v.name)
    var delayedUntil: Long? get() = long(Keys.DELAYED_UNTIL); set(v) = put(Keys.DELAYED_UNTIL, v)

    var delayOptionsMinutes: List<Int>
        get() = parseDelayOptions(kv.get(Keys.DELAY_OPTIONS)) ?: DEFAULT_DELAYS
        set(v) {
            require(isValidDelayOptions(v)) { "1 to 4 options, each 15 minutes to 24 hours" }
            put(Keys.DELAY_OPTIONS, v.joinToString(","))
        }

    var defaultRetentionDays: Int
        get() = int(Keys.DEFAULT_RETENTION, 7)
        set(v) { require(v in 1..365) { "1 to 365 days" }; put(Keys.DEFAULT_RETENTION, v) }

    val botPacePerMinute: Int get() = int(Keys.BOT_PACE, 15)
    val accountMinGapSeconds: Int get() = int(Keys.ACCOUNT_GAP, 10)
    val maxAttempts: Int get() = int(Keys.MAX_ATTEMPTS, 5)
    val botMaxBytes: Long get() = long(Keys.BOT_MAX_BYTES) ?: 52_428_800L
    val botPhotoMaxBytes: Long get() = long(Keys.BOT_PHOTO_MAX) ?: 10_485_760L

    var botId: Long? get() = long(Keys.BOT_ID); set(v) = put(Keys.BOT_ID, v)
    var botUsername: String? get() = kv.get(Keys.BOT_USERNAME); set(v) = put(Keys.BOT_USERNAME, v)
    var chatId: Long? get() = long(Keys.CHAT_ID); set(v) = put(Keys.CHAT_ID, v)
    var chatTitle: String? get() = kv.get(Keys.CHAT_TITLE); set(v) = put(Keys.CHAT_TITLE, v)

    var accountState: AccountValue
        get() = kv.get(Keys.ACCOUNT_STATE)?.let { runCatching { AccountValue.valueOf(it) }.getOrNull() } ?: AccountValue.NONE
        set(v) = put(Keys.ACCOUNT_STATE, v.name)
    var accountName: String? get() = kv.get(Keys.ACCOUNT_NAME); set(v) = put(Keys.ACCOUNT_NAME, v)

    var deletesBlockedReason: String? get() = kv.get(Keys.DELETES_BLOCKED); set(v) = put(Keys.DELETES_BLOCKED, v)

    /** Owner decision D1 (docs/phases/M1.md): may a bot-only setup delete? Default no until the owner decides. */
    var allowBotOnlyDelete: Boolean get() = bool(Keys.ALLOW_BOT_ONLY_DELETE, false); set(v) = put(Keys.ALLOW_BOT_ONLY_DELETE, v)

    var lastScanAt: Long? get() = long(Keys.LAST_SCAN); set(v) = put(Keys.LAST_SCAN, v)
    var lastUploadAt: Long? get() = long(Keys.LAST_UPLOAD); set(v) = put(Keys.LAST_UPLOAD, v)
    var lastCleanAt: Long? get() = long(Keys.LAST_CLEAN); set(v) = put(Keys.LAST_CLEAN, v)
    var lastStopReason: String? get() = kv.get(Keys.LAST_STOP_REASON); set(v) = put(Keys.LAST_STOP_REASON, v)

    /** Debug builds only: retention counts minutes instead of days. */
    var timeWarp: Boolean get() = bool(Keys.TIME_WARP, false); set(v) = put(Keys.TIME_WARP, v)

    companion object {
        val DEFAULT_DELAYS = listOf(120, 300)

        fun isValidDelayOptions(v: List<Int>) = v.size in 1..4 && v.all { it in 15..1440 }

        fun parseDelayOptions(raw: String?): List<Int>? {
            val parsed = raw?.split(",")?.mapNotNull { it.trim().toIntOrNull() } ?: return null
            return parsed.takeIf { isValidDelayOptions(it) }
        }
    }
}
