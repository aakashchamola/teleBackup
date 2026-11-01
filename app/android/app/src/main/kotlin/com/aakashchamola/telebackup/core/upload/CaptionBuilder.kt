package com.aakashchamola.telebackup.core.upload

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Three-line caption, plain text (no Markdown parsing), at most 1024 characters:
 *   file name / taken date and rule name / #tb and the first 12 hex of the SHA-256
 */
object CaptionBuilder {
    const val MAX = 1024
    private val fmt = DateTimeFormatter.ofPattern("d MMM yyyy HH:mm", Locale.ENGLISH)

    fun build(displayName: String, takenAt: Long, ruleName: String, sha256: String?, zone: ZoneId = ZoneId.systemDefault()): String {
        val date = fmt.format(Instant.ofEpochMilli(takenAt).atZone(zone))
        val line2 = "$date · $ruleName"
        val line3 = if (sha256 != null) "#tb ${sha256.take(12)}" else ""
        val extras = (if (line3.isEmpty()) 0 else line3.length + 1) + line2.length + 1
        val room = (MAX - extras).coerceAtLeast(10)
        val name = shorten(displayName, room)
        return listOf(name, line2, line3).filter { it.isNotEmpty() }.joinToString("\n").take(MAX)
    }

    /** Cuts a long name in the middle with "...". */
    fun shorten(text: String, max: Int): String {
        if (text.length <= max) return text
        val keep = max - 3
        val head = (keep + 1) / 2
        val tail = keep / 2
        return text.take(head) + "..." + text.takeLast(tail)
    }
}
