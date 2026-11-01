package com.aakashchamola.telebackup.core.rules

import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant

@Serializable
data class ExportedRule(
    val name: String,
    val folderPath: String,
    val includeSubfolders: Boolean = false,
    val mediaTypes: String = "BOTH",
    val topicName: String? = null,
    val uploadAs: String = "MEDIA",
    val mode: String = "UPLOAD_ONLY",
    val retentionDays: Int = 7,
    val startMode: String = "TODAY",
)

@Serializable
data class ExportedSettings(
    val defaultRetentionDays: Int = 7,
    val delayOptionsMinutes: String = "120,300",
    val allowMobileData: Boolean = false,
)

@Serializable
data class ExportFile(
    val format: String = "telebackup-rules",
    val version: Int = 1,
    val exportedAt: String,
    val settings: ExportedSettings,
    val rules: List<ExportedRule>,
)

/** Rules and a few settings as JSON. No ids, no chat ids, no tokens (docs/DATA_MODEL.md "Export file"). */
object RulesExport {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true; encodeDefaults = true }

    fun export(rules: List<RuleEntity>, topicNames: Map<Long, String>, settings: SettingsRepository, now: Long): String =
        json.encodeToString(
            ExportFile.serializer(),
            ExportFile(
                exportedAt = Instant.ofEpochMilli(now).toString(),
                settings = ExportedSettings(settings.defaultRetentionDays, settings.delayOptionsMinutes.joinToString(","), settings.allowMobileData),
                rules = rules.map {
                    ExportedRule(it.name, it.folderPath, it.includeSubfolders, it.mediaTypes.name, it.topicId?.let(topicNames::get),
                        it.uploadAs.name, it.mode.name, it.retentionDays, it.startMode.name)
                },
            ),
        )

    class BadFile(message: String) : Exception(message)

    /**
     * Turns a file into rules that are safe to add: every one is upload-only, off and in dry run,
     * and a name already in use gets a number. [topicIdByName] finds an existing topic by its name.
     */
    fun import(text: String, existingNames: Collection<String>, topicIdByName: (String) -> Long?, now: Long): List<RuleEntity> {
        val file = try { json.decodeFromString(ExportFile.serializer(), text) } catch (e: Exception) { throw BadFile("That is not a teleBackup rules file.") }
        if (file.format != "telebackup-rules") throw BadFile("That is not a teleBackup rules file.")
        if (file.version > 1) throw BadFile("This file is from a newer teleBackup.")
        val taken = existingNames.map { it.lowercase() }.toMutableSet()
        return file.rules.map { r ->
            var name = r.name.trim().take(RuleValidator.NAME_MAX)
            var n = 2
            val base = name
            while (name.lowercase() in taken) { name = (base.take(RuleValidator.NAME_MAX - 4) + " ($n)"); n++ }
            taken += name.lowercase()
            RuleEntity(
                name = name, folderPath = RuleValidator.normalizeFolder(r.folderPath), includeSubfolders = r.includeSubfolders,
                mediaTypes = enumOr(r.mediaTypes, MediaTypes.BOTH), topicId = r.topicName?.let(topicIdByName),
                uploadAs = enumOr(r.uploadAs, UploadAs.MEDIA), mode = RuleMode.UPLOAD_ONLY,
                retentionDays = r.retentionDays.coerceIn(1, 365), startMode = StartMode.TODAY,   // start dates are not exported; Today avoids re-uploading old files after a reinstall
                enabled = false, dryRun = true, deleteWarningAcceptedAt = null, createdAt = now, updatedAt = now,
            )
        }
    }

    private inline fun <reified E : Enum<E>> enumOr(name: String, default: E): E = enumValues<E>().firstOrNull { it.name == name } ?: default
}
