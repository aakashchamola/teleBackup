package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.telegram.SendJob
import com.aakashchamola.telebackup.core.telegram.SentMessage
import com.aakashchamola.telebackup.core.time.Clock

class FakeClock(var t: Long = 1_800_000_000_000L) : Clock {
    override fun now() = t
    fun advance(ms: Long) { t += ms }
}

object Fx {
    const val NOW = 1_800_000_000_000L
    const val DAY = 86_400_000L

    fun rule(
        id: Long = 1,
        mode: RuleMode = RuleMode.UPLOAD_AND_DELETE,
        warning: Long? = 1L,
        enabled: Boolean = true,
        dryRun: Boolean = false,
        deletedAt: Long? = null,
    ) = RuleEntity(
        id = id, name = "Rule$id", folderPath = "Pictures/teleBackupTest/", mode = mode,
        deleteWarningAcceptedAt = warning, enabled = enabled, dryRun = dryRun, deletedAt = deletedAt,
    )

    fun file(
        id: Long = 1,
        state: FileState = FileState.QUEUED,
        route: Route? = Route.BOT,
        kind: FileKind = FileKind.PHOTO,
        size: Long = 1_000_000,
        verified: Boolean = false,
    ): FileEntity {
        val base = FileEntity(
            id = id, ruleId = 1, path = "/storage/emulated/0/Pictures/teleBackupTest/IMG_$id.jpg",
            displayName = "IMG_$id.jpg", mimeType = "image/jpeg", kind = kind, sizeBytes = size,
            modifiedAt = NOW - 10 * DAY, takenAt = NOW - 10 * DAY, state = state, route = route,
            queuedAt = NOW - 9 * DAY,
        )
        return if (verified || state == FileState.VERIFIED) base.copy(
            state = FileState.VERIFIED, tgChatId = -1001L, tgThreadId = 5L, tgMessageId = 77L,
            uploadedAt = NOW - 8 * DAY, verifiedAt = NOW - 8 * DAY, deleteAfter = NOW - DAY,
        ) else base
    }

    fun sent(
        chat: Long = -1001L, thread: Long? = 5L, id: Long = 77L, size: Long? = 1_000_000,
        w: Int? = null, h: Int? = null, dur: Long? = null, kind: SendAs = SendAs.DOCUMENT,
    ) = SentMessage(chat, thread, id, "uniq", size, w, h, dur, kind)

    fun job(
        sendAs: SendAs = SendAs.DOCUMENT, size: Long = 1_000_000, w: Int? = null, h: Int? = null, dur: Long? = null,
    ) = SendJob(-1001L, 5L, "/x/y.jpg", "y.jpg", "image/jpeg", sendAs, "cap", size, w, h, dur)
}
