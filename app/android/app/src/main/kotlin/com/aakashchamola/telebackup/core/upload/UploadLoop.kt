package com.aakashchamola.telebackup.core.upload

import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.FileStore
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.db.RuleStore
import com.aakashchamola.telebackup.core.db.TopicStore
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.Retention
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.telegram.*
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.verify.ReplyCheck
import com.aakashchamola.telebackup.core.verify.Verifier
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

interface Hasher {
    /** Streaming SHA-256 of the file as lower-case hex. Throws IOException if the file cannot be read. */
    suspend fun sha256(path: String): String
}

interface DiskInspector {
    fun inspect(path: String): DiskFacts
}

/** What the notification and the Home screen show while a run goes on. */
interface ProgressSink {
    fun runStarted(filesTotal: Int, bytesTotal: Long) {}
    fun fileStarted(name: String, bytesTotal: Long, filesDone: Int, filesTotal: Int) {}
    fun fileProgress(name: String, bytesDone: Long, bytesTotal: Long) {}
    fun fileFinished(filesDone: Int, filesTotal: Int) {}
    fun runEnded(reason: StopReason) {}
}

enum class StopReason { QUEUE_EMPTY, PAUSED, OS_STOPPED, NO_INTERNET, NOT_SET_UP, NOTHING_TO_SEND }

data class RunOutcome(val filesDone: Int, val reason: StopReason)

/**
 * One upload run (docs/HOW_IT_WORKS.md section 5). Plain Kotlin, no Android types,
 * so tests drive it with fake senders and a fake clock.
 */
class UploadLoop(
    private val files: FileStore,
    private val rules: RuleStore,
    private val topics: TopicStore,
    private val events: EventLog,
    private val settings: SettingsRepository,
    private val clock: Clock,
    private val pacer: Pacer,
    private val hasher: Hasher,
    private val disk: DiskInspector,
    private val bot: TelegramSender?,
    private val account: TelegramSender?,
    private val progress: ProgressSink = object : ProgressSink {},
    private val zone: java.time.ZoneId = java.time.ZoneId.systemDefault(),
) {
    companion object { const val SHORT_FLOOD_SECONDS = 120L; const val ALBUM_MAX = 10 }

    private var botStopped = false
    private var accountStopped = false
    private val pausedRules = HashSet<Long>()
    private var networkFailsInARow = 0
    private var migratedFor = HashSet<Long>()

    suspend fun run(isStopped: () -> Boolean): RunOutcome {
        if (!controlAllowsRun()) return end(0, StopReason.PAUSED)
        if (settings.chatId == null) return end(0, StopReason.NOT_SET_UP)

        recoverInterrupted()
        val accountReady = { settings.accountState == AccountValue.READY && !accountStopped && account != null }
        val total0 = files.queueCount(clock.now(), allowBot = bot != null, allowAccount = accountReady())
        progress.runStarted(total0.count, total0.bytes)
        var done = 0
        var reason = StopReason.QUEUE_EMPTY

        while (true) {
            if (isStopped()) { reason = StopReason.OS_STOPPED; break }
            if (!controlAllowsRun()) { reason = StopReason.PAUSED; break }
            val now = clock.now()
            val file = files.nextInQueue(
                now, allowBot = bot != null && !botStopped, allowAccount = accountReady(), excludeRuleIds = pausedRules,
            )
            if (file == null) {
                reason = if (files.waitingAccountCount() > 0 || botStopped) StopReason.NOTHING_TO_SEND else StopReason.QUEUE_EMPTY
                break
            }
            val rule = rules.get(file.ruleId)
            if (rule == null || !rule.enabled || rule.deletedAt != null) {
                files.apply(file.id, FileEvent.Ignore, now)
                continue
            }
            val batch = albumOf(file)
            val outcome = if (batch.size >= 2) sendBatch(batch, rule, done, total0.count, isStopped)
            else sendOne(file, rule, done, total0.count, isStopped).let { BatchOutcome(it, if (it == SendStep.Done) 1 else 0) }
            when (outcome.step) {
                SendStep.Done -> { done += outcome.sent; networkFailsInARow = 0; progress.fileFinished(done, total0.count) }
                SendStep.Retry -> Unit
                SendStep.NetworkFail -> {
                    networkFailsInARow++
                    if (networkFailsInARow >= 3) { reason = StopReason.NO_INTERNET; break }
                }
            }
        }
        if (reason == StopReason.QUEUE_EMPTY) settings.mobileOnceUntilEmpty = false
        settings.lastUploadAt = clock.now()
        return end(done, reason)
    }

    private fun end(done: Int, reason: StopReason): RunOutcome {
        settings.lastStopReason = reason.name
        progress.runEnded(reason)
        return RunOutcome(done, reason)
    }

    private fun controlAllowsRun(): Boolean = when (settings.controlState) {
        ControlValue.RUNNING -> true
        ControlValue.PAUSED -> false
        ControlValue.DELAYED -> (settings.delayedUntil ?: 0L) <= clock.now()
    }

    /** Rows left in UPLOADING by a crash or kill become QUEUED, or UPLOADED if Telegram had already answered. */
    private fun recoverInterrupted() {
        val now = clock.now()
        for (f in files.interrupted()) {
            val after = files.apply(f.id, FileEvent.RecoverAfterCrash, now)
            if (after.state == FileState.UPLOADED) {
                val rule = rules.get(after.ruleId)
                if (rule != null) checkAndVerify(after, rule)
            }
        }
    }

    private enum class SendStep { Done, Retry, NetworkFail }

    /** A file that passed the checks, is marked UPLOADING, and has its hash and send job. */
    private class Prep(val file: FileEntity, val job: SendJob, val hash: String)

    /** The checks before any send. Null means "nothing to send for this file now" (it vanished or changed; the row is already updated). */
    private suspend fun prepare(file0: FileEntity, rule: RuleEntity, doneSoFar: Int, total: Int, announce: Boolean): Prep? {
        var file = file0
        val now0 = clock.now()
        val facts = disk.inspect(file.path)
        if (!facts.exists) {
            files.apply(file.id, FileEvent.Vanished, now0)
            events.add(EventKind.GONE, "${file.displayName} was removed from the phone", rule.id, file.id)
            return null
        }
        if (facts.sizeBytes != file.sizeBytes || facts.modifiedAt != file.modifiedAt) {
            // edited since the scan: refresh the row; the next pass uploads the new version
            files.updateDetails(file.copy(sizeBytes = facts.sizeBytes, modifiedAt = facts.modifiedAt, sha256 = null))
            return null
        }
        // a failed file whose waiting time is over goes back to the queue first
        if (file.state == FileState.FAILED) file = files.apply(file.id, FileEvent.BackoffDue, clock.now())
        file = files.apply(file.id, FileEvent.StartUpload, clock.now())
        if (announce) progress.fileStarted(file.displayName, file.sizeBytes, doneSoFar, total)

        val hash = try {
            file.sha256 ?: hasher.sha256(file.path)
        } catch (e: CancellationException) {
            withContext(NonCancellable) { files.apply(file.id, FileEvent.NetworkStop, clock.now()) }
            throw e
        } catch (e: java.io.IOException) {
            files.apply(file.id, FileEvent.Vanished, clock.now())
            return null
        }
        if (file.sha256 == null) files.updateDetails(file.copy(sha256 = hash))

        val job = SendJob(
            chatId = settings.chatId!!, threadId = file.topicId ?: rule.topicId, path = file.path, displayName = file.displayName,
            mimeType = file.mimeType, sendAs = file.sendAs ?: SendAs.DOCUMENT,
            caption = CaptionBuilder.build(file.displayName, file.takenAt, rule.name, hash),
            sizeBytes = file.sizeBytes, width = file.width, height = file.height, durationMs = file.durationMs,
        )
        return Prep(file, job, hash)
    }

    private suspend fun sendOne(file0: FileEntity, rule: RuleEntity, doneSoFar: Int, total: Int, isStopped: () -> Boolean): SendStep {
        val route = file0.route ?: Route.BOT
        pacer.awaitSlot(route)
        val prep = prepare(file0, rule, doneSoFar, total, announce = true) ?: return SendStep.Retry
        return sendPrepared(prep, rule, route, isStopped)
    }

    /** Sends one prepared file by itself and records what Telegram answered. */
    private suspend fun sendPrepared(prep: Prep, rule: RuleEntity, route: Route, isStopped: () -> Boolean): SendStep {
        val file = prep.file; val job = prep.job; val hash = prep.hash
        val sender = if (route == Route.ACCOUNT) account else bot
        if (sender == null) {
            files.apply(file.id, FileEvent.NetworkStop, clock.now())
            if (route == Route.ACCOUNT) accountStopped = true else botStopped = true
            return SendStep.Retry
        }

        val result = try {
            sender.send(job) { sent, tot -> progress.fileProgress(file.displayName, sent, tot) }
        } catch (e: CancellationException) {
            withContext(NonCancellable) { files.apply(file.id, FileEvent.NetworkStop, clock.now()) }
            throw e
        }

        return when (result) {
            is SendResult.Sent -> {
                if (route == Route.BOT) settings.botProblem = false
                val uploaded = files.apply(file.id, FileEvent.Sent(result.message, hash), clock.now())
                events.add(EventKind.UPLOADED, "${file.displayName} uploaded", rule.id, file.id, file.sizeBytes)
                checkAndVerify(uploaded, rule, result.message, job)
                SendStep.Done
            }
            is SendResult.Failed -> handleFailure(file, rule, result.error, isStopped)
        }
    }

    // ----- albums: the photos and videos of one day go together (up to 10 at a time) -----

    /** [first] and the other queued files of the same rule, day, topic and kind that fit in one album. Size 1 means "send it alone". */
    private fun albumOf(first: FileEntity): List<FileEntity> {
        if (!settings.groupByDay || bot == null || botStopped) return listOf(first)
        if ((first.route ?: Route.BOT) != Route.BOT || first.state != FileState.QUEUED) return listOf(first)
        val documents = when (first.sendAs) {
            SendAs.PHOTO, SendAs.VIDEO -> false
            SendAs.DOCUMENT -> true
            null -> return listOf(first)
        }
        val day = java.time.Instant.ofEpochMilli(first.takenAt).atZone(zone).toLocalDate()
        val from = day.atStartOfDay(zone).toInstant().toEpochMilli()
        val to = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        return listOf(first) + files.queuedSameDay(first.ruleId, documents, from, to, first.topicId, first.id, clock.now(), ALBUM_MAX - 1)
    }

    private class BatchOutcome(val step: SendStep, val sent: Int)

    private suspend fun sendBatch(batch: List<FileEntity>, rule: RuleEntity, doneSoFar: Int, total: Int, isStopped: () -> Boolean): BatchOutcome {
        pacer.awaitSlot(Route.BOT)
        val preps = ArrayList<Prep>()
        suspend fun revert(list: List<Prep>) = withContext(NonCancellable) { list.forEach { files.apply(it.file.id, FileEvent.NetworkStop, clock.now()) } }
        try {
            for ((i, f) in batch.withIndex()) prepare(f, rule, doneSoFar, total, announce = false)?.let { preps += it }
        } catch (e: CancellationException) { revert(preps); throw e }
        if (preps.isEmpty()) return BatchOutcome(SendStep.Retry, 0)
        if (preps.size == 1) {
            progress.fileStarted(preps[0].file.displayName, preps[0].file.sizeBytes, doneSoFar, total)
            val s = sendPrepared(preps[0], rule, Route.BOT, isStopped)
            return BatchOutcome(s, if (s == SendStep.Done) 1 else 0)
        }
        val sender = bot
        if (sender == null) { revert(preps); botStopped = true; return BatchOutcome(SendStep.Retry, 0) }

        progress.fileStarted("${preps.size} files of one day", preps.sumOf { it.file.sizeBytes }, doneSoFar, total)
        val result = try {
            sender.sendAlbum(preps.map { it.job }) { sent, tot -> progress.fileProgress("${preps.size} files of one day", sent, tot) }
        } catch (e: CancellationException) { revert(preps); throw e }

        suspend fun oneByOne(): BatchOutcome {
            var sent = 0
            var last = SendStep.Retry
            for ((i, p) in preps.withIndex()) {
                // the same stops as between single files: a pause, a dead token, a deleted topic, no network
                if (isStopped() || botStopped || rule.id in pausedRules || last == SendStep.NetworkFail) {
                    revert(preps.drop(i))
                    break
                }
                last = sendPrepared(p, rule, Route.BOT, isStopped)
                if (last == SendStep.Done) sent++
            }
            return BatchOutcome(if (sent > 0) SendStep.Done else if (last == SendStep.NetworkFail) SendStep.NetworkFail else SendStep.Retry, sent)
        }

        return when (result) {
            AlbumResult.Unsupported -> oneByOne()
            is AlbumResult.Sent -> {
                if (result.messages.size != preps.size) {
                    // Telegram answered with another number of messages than files: do not guess which is which.
                    // The album may well be posted already, so each file takes a normal failed attempt (backoff, then skipped)
                    // instead of going straight back to the queue, which would post it again and again.
                    val err = TgError.BadRequest("the album answer did not match its files")
                    preps.forEach { p ->
                        val after = files.apply(p.file.id, FileEvent.TgFailed(err), clock.now(), settings.maxAttempts, Math.random())
                        events.add(EventKind.RETRIED, "${p.file.displayName}: will check again (${err.userMessage})", rule.id, p.file.id)
                        if (after.state == FileState.SKIPPED) events.add(EventKind.SKIPPED, "${p.file.displayName} skipped: ${err.userMessage}", rule.id, p.file.id)
                    }
                    return BatchOutcome(SendStep.Retry, 0)
                }
                settings.botProblem = false
                preps.zip(result.messages).forEach { (p, msg) ->
                    val uploaded = files.apply(p.file.id, FileEvent.Sent(msg, p.hash), clock.now())
                    events.add(EventKind.UPLOADED, "${p.file.displayName} uploaded", rule.id, p.file.id, p.file.sizeBytes)
                    checkAndVerify(uploaded, rule, msg, p.job)
                }
                BatchOutcome(SendStep.Done, preps.size)
            }
            is AlbumResult.Failed -> when (result.error) {
                TgError.Network -> { revert(preps); BatchOutcome(if (isStopped()) SendStep.Retry else SendStep.NetworkFail, 0) }
                is TgError.FloodWait, TgError.BadToken, is TgError.Forbidden, TgError.TopicMissing, is TgError.ChatMigrated, TgError.AccountLoggedOut -> {
                    // these are about the run, not about one file: the first file takes the blame, the rest wait their turn
                    revert(preps.drop(1))
                    BatchOutcome(handleFailure(preps[0].file, rule, result.error, isStopped), 0)
                }
                // one bad file (or Telegram having a bad moment) must not hold back nine good ones: send them one by one
                else -> oneByOne()
            }
        }
    }

    private fun checkAndVerify(uploaded: FileEntity, rule: RuleEntity, sent: SentMessage? = null, job0: SendJob? = null) {
        val now = clock.now()
        val message = sent ?: SentMessage(
            uploaded.tgChatId ?: 0, uploaded.tgThreadId, uploaded.tgMessageId ?: 0, uploaded.tgFileUniqueId,
            uploaded.tgSize, uploaded.tgWidth, uploaded.tgHeight, uploaded.tgDurationMs, uploaded.sendAs ?: SendAs.DOCUMENT,
        )
        val job = job0 ?: SendJob(
            uploaded.tgChatId ?: 0, uploaded.topicId ?: rule.topicId, uploaded.path, uploaded.displayName, uploaded.mimeType,
            uploaded.sendAs ?: SendAs.DOCUMENT, "", uploaded.sizeBytes, uploaded.width, uploaded.height, uploaded.durationMs,
        )
        when (val check = Verifier.checkReply(job, message)) {
            ReplyCheck.Ok -> {
                val due = if (rule.mode == RuleMode.UPLOAD_AND_DELETE)
                    Retention.deleteAfter(now, rule.retentionDays, settings.timeWarp) else null
                files.apply(uploaded.id, FileEvent.ReplyOk(due), now)
                events.add(EventKind.VERIFIED, "${uploaded.displayName} checked in Telegram", rule.id, uploaded.id)
            }
            is ReplyCheck.Mismatch -> {
                val after = files.apply(uploaded.id, FileEvent.ReplyMismatch(check.reason), now, settings.maxAttempts, Math.random())
                events.add(EventKind.VERIFY_FAILED, "${uploaded.displayName}: Telegram reply did not match (${check.reason})", rule.id, uploaded.id)
                if (after.state == FileState.SKIPPED) events.add(EventKind.SKIPPED, "${uploaded.displayName} skipped after repeated problems", rule.id, uploaded.id)
            }
        }
    }

    private fun handleFailure(file: FileEntity, rule: RuleEntity, err: TgError, isStopped: () -> Boolean): SendStep {
        val now = clock.now()
        val after = files.apply(file.id, FileEvent.TgFailed(err), now, settings.maxAttempts, Math.random())
        Tlog.w("send failed: ${err::class.simpleName}")
        when (err) {
            is TgError.FloodWait -> {
                val until = now + (err.seconds + 1) * 1000
                if (file.route == Route.ACCOUNT) pacer.blockRoute(Route.ACCOUNT, until) else pacer.blockAll(until)
                // a short wait is slept through in this run; a long one leaves the file for a later run
                if (err.seconds <= SHORT_FLOOD_SECONDS && after.state == FileState.QUEUED) {
                    files.updateDetails(after.copy(nextAttemptAt = null))
                }
            }
            TgError.Network -> return if (isStopped()) SendStep.Retry else SendStep.NetworkFail
            TgError.TopicMissing -> {
                pausedRules += rule.id
                (file.topicId ?: rule.topicId)?.let { topics.markMissing(it, true) }
                events.add(EventKind.TOPIC_MISSING, "The topic for ${rule.name} was deleted in Telegram", rule.id)
            }
            TgError.BadToken -> {
                botStopped = true
                settings.botProblem = true
                events.add(EventKind.BOT_PROBLEM, "The bot token no longer works")
            }
            is TgError.Forbidden -> {
                botStopped = true
                settings.botProblem = true
                events.add(EventKind.BOT_PROBLEM, "The bot cannot post to the group")
            }
            TgError.AccountLoggedOut -> {
                accountStopped = true
                settings.accountState = AccountValue.EXPIRED
                events.add(EventKind.LOGIN_EXPIRED, "The Telegram account is logged out")
            }
            is TgError.ChatMigrated -> {
                if (migratedFor.add(file.id)) settings.chatId = err.newChatId
            }
            TgError.TooLarge -> Unit
            is TgError.BadRequest, is TgError.Server -> {
                if (after.state == FileState.FAILED) events.add(EventKind.RETRIED, "${file.displayName}: will try again (${err.userMessage})", rule.id, file.id)
                if (after.state == FileState.SKIPPED) events.add(EventKind.SKIPPED, "${file.displayName} skipped: ${err.userMessage}", rule.id, file.id)
            }
        }
        if (err !is TgError.Network) networkFailsInARow = 0
        return SendStep.Retry
    }
}
