package com.aakashchamola.telebackup.core.rules

import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.model.RuleMode
import com.aakashchamola.telebackup.core.model.StartMode

/** A problem with one field of a rule. [field] is the field id the screen uses. */
data class RuleProblem(val field: String, val message: String)

object RuleValidator {
    const val NAME_MAX = 40

    /**
     * @param otherActiveNames names of the other rules that are not deleted (the rule itself excluded).
     */
    fun validate(rule: RuleEntity, otherActiveNames: Collection<String>, folderExists: Boolean = true): List<RuleProblem> {
        val out = mutableListOf<RuleProblem>()
        val name = rule.name.trim()
        if (name.isEmpty()) out += RuleProblem("name", "Give the rule a name.")
        else if (name.length > NAME_MAX) out += RuleProblem("name", "Use $NAME_MAX characters or fewer.")
        else if (otherActiveNames.any { it.trim().equals(name, ignoreCase = true) }) {
            out += RuleProblem("name", "This name is already used.")
        }
        if (rule.folderPath.isBlank()) out += RuleProblem("folder", "Pick a folder.")
        else if (!folderExists) out += RuleProblem("folder", "That folder is not on this phone.")
        if (rule.retentionDays !in 1..365) out += RuleProblem("retention", "Pick 1 to 365 days.")
        if (rule.startMode == StartMode.SINCE_DATE && rule.startDate == null) {
            out += RuleProblem("startDate", "Pick a date.")
        }
        if (rule.mode == RuleMode.UPLOAD_AND_DELETE && rule.deleteWarningAcceptedAt == null) {
            out += RuleProblem("mode", "Turn on delete from the warning first.")
        }
        return out
    }

    /** Folder paths are stored relative to shared storage, with a trailing slash and no leading slash. */
    fun normalizeFolder(path: String): String {
        val p = path.trim().replace('\\', '/').trimStart('/')
        return if (p.isEmpty() || p.endsWith("/")) p else "$p/"
    }
}
