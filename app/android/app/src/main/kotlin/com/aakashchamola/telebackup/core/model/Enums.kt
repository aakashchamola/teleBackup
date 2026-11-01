package com.aakashchamola.telebackup.core.model

enum class MediaTypes { PHOTOS, VIDEOS, BOTH }
enum class UploadAs { MEDIA, ORIGINAL }
enum class RuleMode { UPLOAD_ONLY, UPLOAD_AND_DELETE }
enum class StartMode { TODAY, SINCE_DATE, EVERYTHING }
enum class FileKind { PHOTO, VIDEO }
enum class Route { BOT, ACCOUNT }
enum class SendAs { PHOTO, VIDEO, DOCUMENT }
enum class ReviewStatus { WAITING, APPROVED, DISMISSED, STALE }
enum class TopicSource { CREATED_BY_APP, FOUND_BY_ACCOUNT }
enum class ControlValue { RUNNING, PAUSED, DELAYED }
enum class AccountValue { NONE, READY, EXPIRED }

enum class FileState {
    QUEUED, UPLOADING, UPLOADED, VERIFIED, DELETED, FAILED, SKIPPED, IGNORED, GONE, CHANGED;

    val terminal: Boolean get() = this == DELETED || this == IGNORED || this == GONE || this == CHANGED
}

enum class EventKind {
    SCAN_DONE, QUEUED_BATCH, UPLOADED, VERIFIED, VERIFY_FAILED, FAILED, SKIPPED, RETRIED, DELETED,
    DELETE_DENIED, CHANGED, GONE, REVIEW_CREATED, REVIEW_APPROVED, PAUSED, RESUMED, DELAYED,
    RUN_STOPPED, LOGIN_EXPIRED, PERMISSION_LOST, PERMISSION_BACK, TOPIC_MISSING, BOT_PROBLEM,
    KILL_SWITCH, SETTINGS_CHANGED
}

/** Why the delete gate said no. One test per value. */
enum class DenyReason {
    NOT_VERIFIED, RULE_UPLOAD_ONLY, NO_WARNING_ACCEPTED, RULE_OFF, DELETES_BLOCKED, NOT_DUE,
    NEEDS_REVIEW, FILE_MISSING, FILE_CHANGED, TELEGRAM_MISMATCH, NO_STRONG_CHECK,
    /** The video went up in parts; the strong check cannot vouch for all of them, so the app never deletes it. */
    SENT_IN_PARTS
}
