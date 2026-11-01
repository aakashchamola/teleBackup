package com.aakashchamola.telebackup.core.rules

import com.aakashchamola.telebackup.core.db.RuleStore
import com.aakashchamola.telebackup.core.model.MediaTypes
import com.aakashchamola.telebackup.core.scan.MediaSource
import java.io.File

data class FolderEntry(
    val path: String,
    val label: String,
    val mediaCount: Int,
    val usedByRule: String?,
    val isSuggestion: Boolean,
    val hint: String? = null,
)

/** A known place photos come from. Gallery photos and videos share a folder, so a suggestion carries its file types. */
data class Suggestion(val label: String, val folder: String, val types: MediaTypes, val hint: String? = null, val preChecked: Boolean = true) {
    /** How the suggestion travels over the bridge: the folder plus its types. */
    val id: String get() = "$folder?types=${types.name.lowercase()}"

    companion object {
        fun parse(id: String): Pair<String, MediaTypes>? {
            val folder = id.substringBefore("?types=", "")
            val t = id.substringAfter("?types=", "")
            val types = MediaTypes.values().firstOrNull { it.name.equals(t, true) } ?: return null
            return if (folder.isEmpty()) null else folder to types
        }
    }
}

/** Suggested folders and folder browsing (docs/UI.md S-FOLDER and O6). [root] is shared storage. */
class FolderCatalog(private val root: File, private val source: MediaSource, private val rules: RuleStore) {
    companion object {
        val KNOWN = listOf(
            Suggestion("Gallery photos", "DCIM/Camera/", MediaTypes.PHOTOS),
            Suggestion("Gallery videos", "DCIM/Camera/", MediaTypes.VIDEOS),
            Suggestion("Screenshots", "Pictures/Screenshots/", MediaTypes.BOTH),
            Suggestion("Screenshots", "DCIM/Screenshots/", MediaTypes.BOTH),
            Suggestion("WhatsApp images", "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/", MediaTypes.PHOTOS),
            Suggestion("WhatsApp images", "WhatsApp/Media/WhatsApp Images/", MediaTypes.PHOTOS),
            Suggestion("WhatsApp video", "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/", MediaTypes.VIDEOS),
            Suggestion("WhatsApp video", "WhatsApp/Media/WhatsApp Video/", MediaTypes.VIDEOS),
            Suggestion("Telegram images", "Telegram/Telegram Images/", MediaTypes.PHOTOS, "These came from Telegram already.", preChecked = false),
            Suggestion("Telegram video", "Telegram/Telegram Video/", MediaTypes.VIDEOS, "These came from Telegram already.", preChecked = false),
        )
        private val HIDDEN_ROOTS = setOf("Android/data", "Android/obb")
        private val MEDIA_EXT = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp", "dng", "mp4", "mkv", "mov", "3gp", "webm", "avi", "m4v")
    }

    /** Known folders that exist on this phone, with how many photos or videos each holds. One entry per label (the first folder that exists). */
    fun suggestions(): List<Pair<Suggestion, FolderEntry>> {
        val usedLabels = HashSet<String>()
        val out = ArrayList<Pair<Suggestion, FolderEntry>>()
        for (s in KNOWN) {
            if ((s.label + s.types.name) in usedLabels) continue
            if (!source.folderExists(s.folder)) continue
            val count = source.list(s.folder, false, s.types).size
            if (count == 0 && !File(root, s.folder).isDirectory) continue
            usedLabels += s.label + s.types.name
            out += s to FolderEntry(s.id, s.label, count, usedBy(s.folder), true, s.hint)
        }
        return out
    }

    private fun usedBy(folder: String): String? = rules.active().firstOrNull { it.folderPath == folder }?.name

    /** The folders directly inside [path] ("" = the top), folders only, with a count of media files in each. */
    fun listFolder(path: String): List<FolderEntry> {
        val dir = if (path.isEmpty()) root else File(root, path)
        if (!dir.isDirectory) return emptyList()
        val rel = RuleValidator.normalizeFolder(path)
        return (dir.listFiles() ?: emptyArray()).filter { it.isDirectory && !it.name.startsWith(".") }
            .map { RuleValidator.normalizeFolder(rel + it.name) to it }
            .filter { (p, _) -> HIDDEN_ROOTS.none { p.trimEnd('/') == it } }
            .sortedBy { it.second.name.lowercase() }
            .map { (p, f) ->
                val count = (f.listFiles() ?: emptyArray()).count { it.isFile && it.extension.lowercase() in MEDIA_EXT }
                FolderEntry(p, f.name, count, usedBy(p), false)
            }
    }
}
