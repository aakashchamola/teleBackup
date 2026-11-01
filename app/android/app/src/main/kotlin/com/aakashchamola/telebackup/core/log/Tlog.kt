package com.aakashchamola.telebackup.core.log

import android.util.Log

/** Masks secrets in any text before it reaches a log or a screen. */
object Redactor {
    private val botToken = Regex("""\d{6,}:[A-Za-z0-9_-]{30,}""")
    private val hex32 = Regex("""\b[0-9a-fA-F]{32}\b""")
    private val phonePlus = Regex("""\+\d[\d ()-]{7,}\d""")
    private val phoneGrouped = Regex("""\b\d{3,5}[ -]\d{3,5}[ -]?\d{2,6}\b""")
    private val loginCode = Regex("""(?i)(code\D{0,4})\d{5,6}""")
    private val urlToken = Regex("""/bot[^/\s]+/""")

    fun redact(text: String): String = text
        .replace(urlToken, "/bot***/")
        .replace(botToken, "***token***")
        .replace(hex32, "***hash***")
        .replace(phonePlus, "***phone***")
        .replace(phoneGrouped, "***phone***")
        .replace(loginCode) { it.groupValues[1] + "***" }
}

/** The only logger. Tag TeleBackup, everything redacted. Tests can capture lines through [sink]. */
object Tlog {
    const val TAG = "TeleBackup"

    @Volatile var sink: ((level: String, line: String) -> Unit)? = null

    fun d(msg: String) = emit("D", msg)
    fun i(msg: String) = emit("I", msg)
    fun w(msg: String, t: Throwable? = null) = emit("W", msg + (t?.let { " ${it.javaClass.simpleName}" } ?: ""))
    fun e(msg: String, t: Throwable? = null) = emit("E", msg + (t?.let { " ${it.javaClass.simpleName}: ${it.message}" } ?: ""))

    private fun emit(level: String, msg: String) {
        val line = Redactor.redact(msg)
        sink?.invoke(level, line)
        try {
            when (level) {
                "D" -> Log.d(TAG, line)
                "I" -> Log.i(TAG, line)
                "W" -> Log.w(TAG, line)
                else -> Log.e(TAG, line)
            }
        } catch (_: Throwable) {
            // plain JVM tests have no android.util.Log
        }
    }
}
