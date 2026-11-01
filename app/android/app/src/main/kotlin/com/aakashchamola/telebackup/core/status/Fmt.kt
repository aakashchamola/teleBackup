package com.aakashchamola.telebackup.core.status

import com.aakashchamola.telebackup.core.control.ControlState
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Plain-word formatting shared by notifications and the diagnostics text. */
object Fmt {
    /** 412 MB, 1.2 GB, 3.2 MB, 640 KB. */
    fun size(bytes: Long): String {
        val b = bytes.coerceAtLeast(0).toDouble()
        return when {
            b >= 1e9 -> trim(b / 1e9) + " GB"
            b >= 1e6 -> trim(b / 1e6) + " MB"
            b >= 1e3 -> trim(b / 1e3) + " KB"
            else -> "${bytes.coerceAtLeast(0)} B"
        }
    }

    private fun trim(v: Double): String = if (v >= 100) "%.0f".format(Locale.ENGLISH, v) else "%.1f".format(Locale.ENGLISH, v).removeSuffix(".0")

    fun clock(epochMs: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        DateTimeFormatter.ofPattern("HH:mm", Locale.ENGLISH).format(Instant.ofEpochMilli(epochMs).atZone(zone))

    fun delayLabel(minutes: Int): String = "Delay " + ControlState.describe(minutes).replace(" hours", "h").replace(" hour", "h").replace(" minutes", " min")
}
