package com.aakashchamola.telebackup.core.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.aakashchamola.telebackup.core.model.*

@Entity(tableName = "rules", indices = [Index("deletedAt")])
data class RuleEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val folderPath: String,
    val includeSubfolders: Boolean = false,
    val mediaTypes: MediaTypes = MediaTypes.BOTH,
    val topicId: Long? = null,
    val uploadAs: UploadAs = UploadAs.MEDIA,
    val mode: RuleMode = RuleMode.UPLOAD_ONLY,
    val retentionDays: Int = 7,
    val startMode: StartMode = StartMode.TODAY,
    val startDate: Long? = null,
    val enabled: Boolean = true,
    val dryRun: Boolean = true,
    val deleteWarningAcceptedAt: Long? = null,
    val deletedAt: Long? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
)

@Entity(tableName = "topics")
data class TopicEntity(
    @PrimaryKey val threadId: Long,
    val chatId: Long,
    val name: String,
    val iconColor: Int? = null,
    val source: TopicSource = TopicSource.CREATED_BY_APP,
    val missing: Boolean = false,
    val createdAt: Long = 0,
)

@Entity(
    tableName = "files",
    indices = [
        Index(value = ["ruleId", "path", "sizeBytes", "modifiedAt"], unique = true),
        Index(value = ["state", "nextAttemptAt"]),
        Index(value = ["ruleId", "state"]),
        Index(value = ["state", "deleteAfter"]),
        Index(value = ["takenAt"]),
        Index(value = ["sha256"]),
    ],
)
data class FileEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val ruleId: Long,
    val mediaStoreId: Long? = null,
    val path: String,
    val displayName: String,
    val mimeType: String,
    val kind: FileKind,
    val sizeBytes: Long,
    val modifiedAt: Long,
    val takenAt: Long,
    val width: Int? = null,
    val height: Int? = null,
    val durationMs: Long? = null,
    val sha256: String? = null,
    val state: FileState = FileState.QUEUED,
    val route: Route? = null,
    val sendAs: SendAs? = null,
    val attempts: Int = 0,
    val nextAttemptAt: Long? = null,
    val lastError: String? = null,
    val tgChatId: Long? = null,
    val tgThreadId: Long? = null,
    val tgMessageId: Long? = null,
    val tgFileUniqueId: String? = null,
    val tgSize: Long? = null,
    val tgWidth: Int? = null,
    val tgHeight: Int? = null,
    val tgDurationMs: Long? = null,
    val queuedAt: Long = 0,
    val uploadedAt: Long? = null,
    val verifiedAt: Long? = null,
    val deleteAfter: Long? = null,
    val deletedAt: Long? = null,
    val freedBytes: Long = 0,
    val reviewId: Long? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
)

@Entity(tableName = "reviews", indices = [Index("ruleId")])
data class ReviewEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val ruleId: Long,
    val createdAt: Long,
    val fileCount: Int,
    val totalBytes: Long,
    val status: ReviewStatus = ReviewStatus.WAITING,
    val decidedAt: Long? = null,
)

@Entity(tableName = "events", indices = [Index("at")])
data class EventEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val at: Long,
    val kind: EventKind,
    val ruleId: Long? = null,
    val fileId: Long? = null,
    val bytes: Long? = null,
    val message: String,
)

@Entity(tableName = "settings")
data class SettingEntity(
    @PrimaryKey val key: String,
    val value: String,
)
