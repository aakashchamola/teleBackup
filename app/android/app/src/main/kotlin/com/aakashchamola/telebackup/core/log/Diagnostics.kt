package com.aakashchamola.telebackup.core.log

import com.aakashchamola.telebackup.core.db.EventEntity
import com.aakashchamola.telebackup.core.db.StateCount
import com.aakashchamola.telebackup.core.status.Fmt
import com.aakashchamola.telebackup.core.status.PermissionState
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

data class DiagnosticsInput(
    val appVersion: String,
    val androidVersion: String,
    val phoneModel: String,
    val permissions: PermissionState,
    val lastScanAt: Long?,
    val lastUploadAt: Long?,
    val lastCleanAt: Long?,
    val lastStopReason: String?,
    val counts: List<StateCount>,
    val recentProblems: List<EventEntity>,
    val workStates: List<String>,
    val setupDone: Boolean,
    val accountState: String,
    val deletesBlockedReason: String?,
)

/** The text on the Diagnostics screen. Nothing secret goes in, and the whole text is redacted once more on the way out. */
object Diagnostics {
    const val HEADER = "No passwords, tokens or phone numbers are included."
    private val fmt = DateTimeFormatter.ofPattern("d MMM yyyy HH:mm", Locale.ENGLISH)

    fun build(i: DiagnosticsInput, zone: ZoneId = ZoneId.systemDefault()): String {
        fun t(ms: Long?) = ms?.let { fmt.format(Instant.ofEpochMilli(it).atZone(zone)) } ?: "never"
        fun yn(b: Boolean) = if (b) "yes" else "no"
        val byState = i.counts.groupBy { it.state }.mapValues { (_, v) -> v.sumOf { it.count } to v.sumOf { it.bytes } }
        val sb = StringBuilder()
        sb.appendLine(HEADER).appendLine()
        sb.appendLine("teleBackup ${i.appVersion}")
        sb.appendLine("Android ${i.androidVersion}, ${i.phoneModel}")
        sb.appendLine("Setup finished: ${yn(i.setupDone)}  Account: ${i.accountState}")
        sb.appendLine()
        sb.appendLine("Permissions")
        sb.appendLine("  All files access: ${yn(i.permissions.allFiles)}")
        sb.appendLine("  Notifications: ${yn(i.permissions.notifications)}")
        sb.appendLine("  Battery exemption: ${yn(i.permissions.batteryExempt)}")
        sb.appendLine("  Photos and videos: ${yn(i.permissions.mediaRead)}")
        sb.appendLine("  Deletes blocked: ${i.deletesBlockedReason ?: "no"}")
        sb.appendLine()
        sb.appendLine("Last scan: ${t(i.lastScanAt)}")
        sb.appendLine("Last upload: ${t(i.lastUploadAt)}")
        sb.appendLine("Last clean: ${t(i.lastCleanAt)}")
        sb.appendLine("Last run ended: ${i.lastStopReason ?: "-"}")
        sb.appendLine()
        sb.appendLine("Files by state")
        if (byState.isEmpty()) sb.appendLine("  none")
        byState.entries.sortedBy { it.key.name }.forEach { (s, v) -> sb.appendLine("  ${s.name.lowercase()}: ${v.first} (${Fmt.size(v.second)})") }
        sb.appendLine()
        sb.appendLine("Background jobs")
        if (i.workStates.isEmpty()) sb.appendLine("  none") else i.workStates.forEach { sb.appendLine("  $it") }
        sb.appendLine()
        sb.appendLine("Last problems")
        if (i.recentProblems.isEmpty()) sb.appendLine("  none")
        i.recentProblems.take(50).forEach { sb.appendLine("  ${t(it.at)}  ${it.kind.name.lowercase()}  ${it.message}") }
        return Redactor.redact(sb.toString())
    }
}
