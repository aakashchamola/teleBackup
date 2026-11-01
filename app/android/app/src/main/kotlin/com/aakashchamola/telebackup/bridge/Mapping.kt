package com.aakashchamola.telebackup.bridge

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.db.TopicEntity
import com.aakashchamola.telebackup.core.model.AccountValue
import com.aakashchamola.telebackup.core.model.ControlValue
import com.aakashchamola.telebackup.core.status.StatusSnapshot
import com.aakashchamola.telebackup.core.model.MediaTypes as CoreMediaTypes
import com.aakashchamola.telebackup.core.model.RuleMode as CoreRuleMode
import com.aakashchamola.telebackup.core.model.StartMode as CoreStartMode
import com.aakashchamola.telebackup.core.model.UploadAs as CoreUploadAs
import com.aakashchamola.telebackup.core.model.FileState as CoreFileState
import com.aakashchamola.telebackup.core.status.AttentionKind as CoreAttentionKind
import com.aakashchamola.telebackup.core.status.RunState as CoreRunState
import com.aakashchamola.telebackup.core.status.Attention as CoreAttention

/** Converting between the core's types and the generated bridge types. Enum names are the same on both sides. */
internal inline fun <reified B : Enum<B>> Enum<*>.asBridge(): B = enumValueOf<B>(name)
internal inline fun <reified C : Enum<C>> Enum<*>.asCore(): C = enumValueOf<C>(name)

internal fun StatusSnapshot.toBridge() = Status(
    control = control.asBridge<ControlState>(),
    delayedUntil = delayedUntil,
    run = run.asBridge<RunState>(),
    currentFileName = currentFileName,
    currentFileBytesDone = currentFileBytesDone,
    currentFileBytesTotal = currentFileBytesTotal,
    runFilesDone = runFilesDone.toLong(),
    runFilesTotal = runFilesTotal.toLong(),
    queuedCount = queuedCount.toLong(),
    queuedBytes = queuedBytes,
    waitingAccountCount = waitingAccountCount.toLong(),
    todayUploaded = todayUploaded.toLong(),
    todayFreedBytes = todayFreedBytes,
    todaySkipped = todaySkipped.toLong(),
    freedBytesTotal = freedBytesTotal,
    lastScanAt = lastScanAt,
    lastUploadAt = lastUploadAt,
    lastStopReason = lastStopReason,
    attention = attention.map { it.toBridge() },
    onUnmeteredNetwork = onUnmeteredNetwork,
)

internal fun CoreAttention.toBridge() = Attention(kind.asBridge<AttentionKind>(), text, ruleId, count?.toLong())

internal fun RuleEntity.toBridge() = Rule(
    id = id, name = name, folderPath = folderPath, includeSubfolders = includeSubfolders,
    mediaTypes = mediaTypes.asBridge<MediaTypes>(), topicId = topicId, newTopicName = null,
    uploadAs = uploadAs.asBridge<UploadAs>(), mode = mode.asBridge<RuleMode>(), retentionDays = retentionDays.toLong(),
    startMode = startMode.asBridge<StartMode>(), startDate = startDate, enabled = enabled, dryRun = dryRun,
    deleteWarningAccepted = deleteWarningAcceptedAt != null, sortDocuments = sortDocuments,
)

/** A rule from the screen. [acceptedAt] is when the delete warning was accepted before (kept), or now if it was just accepted. */
internal fun Rule.toEntity(existing: RuleEntity?, now: Long, topicId: Long?) = RuleEntity(
    id = existing?.id ?: 0, name = name, folderPath = folderPath, includeSubfolders = includeSubfolders,
    mediaTypes = mediaTypes.asCore<CoreMediaTypes>(), topicId = topicId,
    uploadAs = uploadAs.asCore<CoreUploadAs>(), mode = mode.asCore<CoreRuleMode>(), retentionDays = retentionDays.toInt(),
    startMode = startMode.asCore<CoreStartMode>(), startDate = startDate, enabled = enabled, dryRun = dryRun,
    deleteWarningAcceptedAt = if (deleteWarningAccepted) (existing?.deleteWarningAcceptedAt ?: now) else null,
    deletedAt = existing?.deletedAt, createdAt = existing?.createdAt ?: now, updatedAt = now, sortDocuments = sortDocuments,
)

internal fun TopicEntity.toBridge() = Topic(threadId, name, missing, source == com.aakashchamola.telebackup.core.model.TopicSource.CREATED_BY_APP)

internal fun FileEntity.toBridge(ruleName: String, chatId: Long?) = FileItem(
    id = id, ruleId = ruleId, ruleName = ruleName, displayName = displayName, path = path, sizeBytes = sizeBytes,
    state = state.asBridge<FileState>(), takenAt = takenAt, width = width?.toLong(), height = height?.toLong(), durationMs = durationMs,
    sendAs = sendAs?.name, shortHash = sha256?.take(12), telegramLink = telegramLink(chatId),
    queuedAt = queuedAt.takeIf { it > 0 }, uploadedAt = uploadedAt, verifiedAt = verifiedAt, deleteAfter = deleteAfter,
    deletedAt = deletedAt, lastError = lastError, attempts = attempts.toLong(),
)

/** https://t.me/c/<chat id without -100>/<message id> opens the message for members of the group. */
internal fun FileEntity.telegramLink(chatId: Long?): String? {
    val chat = tgChatId ?: chatId ?: return null
    val msg = tgMessageId ?: return null
    val internal = chat.toString().removePrefix("-100")
    if (internal == chat.toString()) return null
    val thread = tgThreadId
    return if (thread != null) "https://t.me/c/$internal/$thread/$msg" else "https://t.me/c/$internal/$msg"
}

internal fun com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.toBridge(): AccountState = when (this) {
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.NONE -> AccountState.NONE
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.WAIT_PARAMS -> AccountState.WAIT_PARAMS
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.WAIT_PHONE -> AccountState.WAIT_PHONE
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.WAIT_CODE -> AccountState.WAIT_CODE
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.WAIT_PASSWORD -> AccountState.WAIT_PASSWORD
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.WAIT_OTHER -> AccountState.WAIT_OTHER
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.READY -> AccountState.READY
    com.aakashchamola.telebackup.core.telegram.account.AccountSnapshot.Step.EXPIRED -> AccountState.EXPIRED
}

internal fun AccountValue.toBridge(): AccountState = when (this) {
    AccountValue.NONE -> AccountState.NONE
    AccountValue.READY -> AccountState.READY
    AccountValue.EXPIRED -> AccountState.EXPIRED
}
