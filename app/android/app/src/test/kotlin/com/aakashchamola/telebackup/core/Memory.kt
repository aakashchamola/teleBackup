package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.db.*
import com.aakashchamola.telebackup.core.clean.*
import com.aakashchamola.telebackup.core.control.Scheduler
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.scan.MediaItem
import com.aakashchamola.telebackup.core.scan.MediaSource
import com.aakashchamola.telebackup.core.telegram.*
import com.aakashchamola.telebackup.core.upload.DiskInspector
import com.aakashchamola.telebackup.core.upload.Hasher

class MemKv : KeyValueStore {
    private val m = HashMap<String, String>()
    override fun get(key: String) = m[key]
    override fun put(key: String, value: String?) { if (value == null) m.remove(key) else m[key] = value }
    override fun all() = HashMap(m)
}

class MemRules : RuleStore {
    val rows = LinkedHashMap<Long, RuleEntity>()
    private var next = 1L
    override fun get(id: Long) = rows[id]
    override fun active() = rows.values.filter { it.deletedAt == null }
    override fun all() = rows.values.toList()
    override fun insert(rule: RuleEntity): Long { val id = next++; rows[id] = rule.copy(id = id); return id }
    override fun update(rule: RuleEntity) { rows[rule.id] = rule }
}

class MemTopics : TopicStore {
    val rows = HashMap<Long, TopicEntity>()
    override fun get(threadId: Long) = rows[threadId]
    override fun list(chatId: Long) = rows.values.filter { it.chatId == chatId }
    override fun upsert(topic: TopicEntity) { rows[topic.threadId] = topic }
    override fun markMissing(threadId: Long, missing: Boolean) { rows[threadId]?.let { rows[threadId] = it.copy(missing = missing) } }
}

class MemReviews : ReviewStore {
    val rows = LinkedHashMap<Long, ReviewEntity>()
    private var next = 1L
    override fun get(id: Long) = rows[id]
    override fun waitingFor(ruleId: Long) = rows.values.firstOrNull { it.ruleId == ruleId && it.status == ReviewStatus.WAITING }
    override fun allWaiting() = rows.values.filter { it.status == ReviewStatus.WAITING }
    override fun insert(review: ReviewEntity): Long { val id = next++; rows[id] = review.copy(id = id); return id }
    override fun update(review: ReviewEntity) { rows[review.id] = review }
}

class MemEvents : EventStore {
    val rows = ArrayList<EventEntity>()
    private var next = 1L
    override fun insert(event: EventEntity) { rows += event.copy(id = next++) }
    override fun page(kinds: Set<EventKind>?, ruleId: Long?, search: String?, beforeId: Long?, limit: Int) =
        rows.asReversed().filter {
            (kinds == null || it.kind in kinds) && (ruleId == null || it.ruleId == ruleId) &&
                (search == null || it.message.contains(search, true)) && (beforeId == null || it.id < beforeId)
        }.take(limit)
    override fun prune(before: Long): Int { val n = rows.count { it.at < before }; rows.removeAll { it.at < before }; return n }
    override fun lastOf(kind: EventKind) = rows.lastOrNull { it.kind == kind }
    override fun recentFor(fileId: Long) = rows.filter { it.fileId == fileId }
    fun kinds() = rows.map { it.kind }
}

class MemFiles : FileStore {
    val rows = LinkedHashMap<Long, FileEntity>()
    private var next = 1L
    override fun get(id: Long) = rows[id]
    override fun find(ruleId: Long, path: String, sizeBytes: Long, modifiedAt: Long) =
        rows.values.firstOrNull { it.ruleId == ruleId && it.path == path && it.sizeBytes == sizeBytes && it.modifiedAt == modifiedAt }
    override fun findByPath(ruleId: Long, path: String) = rows.values.filter { it.ruleId == ruleId && it.path == path }
    override fun insertAll(files: List<FileEntity>): Int {
        var n = 0
        for (f in files) {
            if (find(f.ruleId, f.path, f.sizeBytes, f.modifiedAt) != null) continue
            val id = if (f.id != 0L) f.id else next++
            if (id >= next) next = id + 1
            rows[id] = f.copy(id = id); n++
        }
        return n
    }
    override fun updateDetails(file: FileEntity) {
        val cur = rows[file.id] ?: error("no such file")
        require(cur.state == file.state) { "updateDetails must not change the state" }
        rows[file.id] = file
    }
    override fun apply(id: Long, event: FileEvent, now: Long, maxAttempts: Int, jitter01: Double): FileEntity {
        val cur = rows[id] ?: error("no such file $id")
        val next = FileStateMachine.transition(cur, event, now, maxAttempts, jitter01)
        rows[id] = next
        return next
    }
    private fun ruleOn(f: FileEntity, rules: RuleStore?) = true
    var rulesForQueue: RuleStore? = null
    override fun nextInQueue(now: Long, allowBot: Boolean, allowAccount: Boolean, excludeRuleIds: Set<Long>): FileEntity? =
        rows.values.filter { f ->
            val rule = rulesForQueue?.get(f.ruleId)
            (rule == null || (rule.enabled && rule.deletedAt == null)) &&
                f.ruleId !in excludeRuleIds &&
                ((f.state == FileState.QUEUED && (f.nextAttemptAt == null || f.nextAttemptAt <= now)) ||
                    (f.state == FileState.FAILED && (f.nextAttemptAt ?: Long.MAX_VALUE) <= now)) &&
                (if (f.route == Route.ACCOUNT) allowAccount else allowBot)
        }.sortedWith(compareBy<FileEntity> { it.takenAt }.thenBy { it.id }).firstOrNull()
    override fun queuedSameDay(ruleId: Long, documents: Boolean, from: Long, to: Long, topicId: Long?, exceptId: Long, now: Long, limit: Int): List<FileEntity> =
        rows.values.filter { f ->
            f.ruleId == ruleId && f.state == FileState.QUEUED && (f.nextAttemptAt == null || f.nextAttemptAt <= now) &&
                (f.route == Route.BOT || f.route == null) && f.takenAt >= from && f.takenAt < to && f.topicId == topicId && f.id != exceptId &&
                (if (documents) f.sendAs == SendAs.DOCUMENT else (f.sendAs == SendAs.PHOTO || f.sendAs == SendAs.VIDEO))
        }.sortedWith(compareBy<FileEntity> { it.takenAt }.thenBy { it.id }).take(limit)
    override fun queueCount(now: Long, allowBot: Boolean, allowAccount: Boolean): QueueCount {
        val q = rows.values.filter { f ->
            ((f.state == FileState.QUEUED) || (f.state == FileState.FAILED && (f.nextAttemptAt ?: Long.MAX_VALUE) <= now)) &&
                (if (f.route == Route.ACCOUNT) allowAccount else allowBot)
        }
        return QueueCount(q.size, q.sumOf { it.sizeBytes })
    }
    override fun waitingAccountCount() = rows.values.count { it.state == FileState.QUEUED && it.route == Route.ACCOUNT }
    override fun earliestRetryAt() = rows.values.filter { it.state == FileState.FAILED || it.state == FileState.QUEUED }.mapNotNull { it.nextAttemptAt }.minOrNull()
    override fun interrupted() = rows.values.filter { it.state == FileState.UPLOADING }
    override fun byRuleAndStates(ruleId: Long, states: Set<FileState>) = rows.values.filter { it.ruleId == ruleId && it.state in states }
    override fun verifiedDue(ruleId: Long, now: Long, limit: Int) =
        rows.values.filter { it.ruleId == ruleId && it.state == FileState.VERIFIED && it.partCount == 1 && (it.deleteAfter ?: Long.MAX_VALUE) <= now }
            .sortedBy { it.takenAt }.take(limit)
    override fun inReview(reviewId: Long) = rows.values.filter { it.reviewId == reviewId }
    override fun setReview(fileIds: List<Long>, reviewId: Long?) { fileIds.forEach { id -> rows[id]?.let { rows[id] = it.copy(reviewId = reviewId) } } }
    override fun stateCounts() = rows.values.groupBy { it.ruleId to it.state }.map { (k, v) -> StateCount(k.first, k.second, v.size, v.sumOf { it.sizeBytes }) }
    override fun freedBytesSince(since: Long) = rows.values.filter { (it.deletedAt ?: -1) >= since }.sumOf { it.freedBytes }
    override fun freedBytesTotal() = rows.values.filter { it.state == FileState.DELETED }.sumOf { it.freedBytes }
    override fun uploadedCountSince(since: Long) = rows.values.count { (it.uploadedAt ?: -1) >= since }
    override fun skippedCountSince(since: Long) = rows.values.count { it.state == FileState.SKIPPED && it.updatedAt >= since }
    override fun page(ruleId: Long?, state: FileState?, cursor: Long?, limit: Int) =
        rows.values.filter { (ruleId == null || it.ruleId == ruleId) && (state == null || it.state == state) && (cursor == null || it.id < cursor) }
            .sortedByDescending { it.id }.take(limit)
    override fun setDeleteAfterForRule(ruleId: Long, deleteAfter: (FileEntity) -> Long?) {
        rows.values.filter { it.ruleId == ruleId && it.state == FileState.VERIFIED }.forEach { rows[it.id] = it.copy(deleteAfter = deleteAfter(it)) }
    }
}

class FakeMedia : MediaSource {
    val items = ArrayList<MediaItem>()
    val existing = HashSet<String>()
    var folderOk = true
    override fun list(folderPath: String, includeSubfolders: Boolean, types: MediaTypes) =
        items.filter {
            it.path.contains("/$folderPath") && (includeSubfolders || !it.path.substringAfter("/$folderPath").contains('/')) &&
                (types == MediaTypes.BOTH || (types == MediaTypes.PHOTOS) == (it.kind == FileKind.PHOTO))
        }
    override fun exists(path: String) = path in existing
    override fun folderExists(folderPath: String) = folderOk
    fun add(item: MediaItem) { items += item; existing += item.path }
    fun remove(path: String) { items.removeAll { it.path == path }; existing -= path }
}

class FakeDisk : DiskInspector {
    val facts = HashMap<String, DiskFacts>()
    override fun inspect(path: String) = facts[path] ?: DiskFacts(false, 0, 0)
    fun sync(f: FileEntity) { facts[f.path] = DiskFacts(true, f.sizeBytes, f.modifiedAt) }
}

class FakeHasher : Hasher {
    var calls = 0
    override suspend fun sha256(path: String): String { calls++; return "ab".repeat(32) }
}

class FakeSender(var responder: (SendJob) -> SendResult) : TelegramSender {
    val jobs = ArrayList<SendJob>()
    /** Albums are off unless a test turns them on, so the older tests keep seeing one send per file. */
    var albumsSupported = false
    val albums = ArrayList<List<SendJob>>()
    var albumResponder: ((List<SendJob>) -> AlbumResult?)? = null
    override suspend fun sendAlbum(jobs: List<SendJob>, progress: (Long, Long) -> Unit): AlbumResult {
        if (!albumsSupported) return AlbumResult.Unsupported
        albums += jobs
        albumResponder?.invoke(jobs)?.let { return it }
        return AlbumResult.Sent(jobs.mapIndexed { i, j ->
            SentMessage(j.chatId, j.threadId, 5000L + albums.size * 20 + i, "u", j.sizeBytes, j.width, j.height, j.durationMs, j.sendAs)
        })
    }
    override suspend fun send(job: SendJob, progress: (Long, Long) -> Unit): SendResult {
        jobs += job
        progress(job.sizeBytes, job.sizeBytes)
        return responder(job)
    }
    companion object {
        /** Answers like Telegram would for a good upload. */
        fun ok(chat: Long = -1001L, startId: Long = 1000) = FakeSender { j ->
            SendResult.Sent(SentMessage(chat, j.threadId, 0, "u", null, null, null, null, j.sendAs))
        }.also { s ->
            var id = startId
            s.responder = { j ->
                SendResult.Sent(SentMessage(j.chatId, j.threadId, id++, "u", j.sizeBytes,
                    j.width, j.height, j.durationMs, j.sendAs))
            }
        }
    }
}

class FakeDeleter : FileDeleter {
    val deleted = ArrayList<FileEntity>()
    var fail: String? = null
    override fun removeFromPhone(file: FileEntity): DeleteOutcome {
        fail?.let { return DeleteOutcome.Failed(it) }
        deleted += file
        return DeleteOutcome.Deleted(file.sizeBytes)
    }
}

class FakeScheduler : Scheduler {
    val calls = ArrayList<String>()
    override fun enqueueUpload() { calls += "upload" }
    override fun enqueueResumeAt(delayMs: Long) { calls += "resumeAt:$delayMs" }
    override fun cancelResumeAt() { calls += "cancelResumeAt" }
    override fun enqueueScanNow(ruleId: Long?) { calls += "scan:$ruleId" }
    override fun enqueueCleanNow(reviewId: Long?) { calls += "clean:$reviewId" }
    override fun enqueueRetryAt(delayMs: Long) { calls += "retry:$delayMs" }
}

class FakeAccountVerifier(var answer: AccountCheck = AccountCheck.OK) : AccountVerifier {
    val calls = ArrayList<Long>()
    override suspend fun recheck(file: FileEntity): AccountCheck { calls += file.id; return answer }
}
