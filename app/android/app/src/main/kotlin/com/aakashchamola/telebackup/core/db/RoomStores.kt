package com.aakashchamola.telebackup.core.db

import com.aakashchamola.telebackup.core.model.*

class RoomRuleStore(private val db: AppDatabase) : RuleStore {
    private val dao = db.ruleDao()
    override fun get(id: Long) = dao.get(id)
    override fun active() = dao.active()
    override fun all() = dao.all()
    override fun insert(rule: RuleEntity) = dao.insert(rule)
    override fun update(rule: RuleEntity) = dao.update(rule)
}

class RoomTopicStore(db: AppDatabase) : TopicStore {
    private val dao = db.topicDao()
    override fun get(threadId: Long) = dao.get(threadId)
    override fun list(chatId: Long) = dao.list(chatId)
    override fun upsert(topic: TopicEntity) = dao.upsert(topic)
    override fun markMissing(threadId: Long, missing: Boolean) = dao.markMissing(threadId, missing)
}

class RoomReviewStore(db: AppDatabase) : ReviewStore {
    private val dao = db.reviewDao()
    override fun get(id: Long) = dao.get(id)
    override fun waitingFor(ruleId: Long) = dao.waitingFor(ruleId)
    override fun allWaiting() = dao.allWaiting()
    override fun insert(review: ReviewEntity) = dao.insert(review)
    override fun update(review: ReviewEntity) = dao.update(review)
}

class RoomEventStore(db: AppDatabase) : EventStore {
    private val dao = db.eventDao()
    override fun insert(event: EventEntity) = dao.insert(event)
    override fun page(kinds: Set<EventKind>?, ruleId: Long?, search: String?, beforeId: Long?, limit: Int) =
        dao.page(kinds == null, kinds?.toList() ?: listOf(EventKind.SCAN_DONE), ruleId, search?.takeIf { it.isNotBlank() }, beforeId, limit)
    override fun prune(before: Long) = dao.prune(before)
    override fun lastOf(kind: EventKind) = dao.lastOf(kind)
    override fun recentFor(fileId: Long) = dao.recentFor(fileId)
}

class RoomKeyValueStore(db: AppDatabase) : KeyValueStore {
    private val dao = db.settingDao()
    override fun get(key: String) = dao.get(key)
    override fun put(key: String, value: String?) { if (value == null) dao.remove(key) else dao.put(SettingEntity(key, value)) }
    override fun all() = dao.all().associate { it.key to it.value }
}

/** The only writer of file rows. A state changes only through [apply], which runs the state machine inside a transaction. */
class RoomFileStore(private val db: AppDatabase) : FileStore {
    private val dao = db.fileDao()

    override fun get(id: Long) = dao.get(id)
    override fun find(ruleId: Long, path: String, sizeBytes: Long, modifiedAt: Long) = dao.find(ruleId, path, sizeBytes, modifiedAt)
    override fun findByPath(ruleId: Long, path: String) = dao.findByPath(ruleId, path)

    override fun insertAll(files: List<FileEntity>): Int = db.runInTransaction<Int> { dao.insertAll(files).count { it != -1L } }

    override fun updateDetails(file: FileEntity) = db.runInTransaction {
        val cur = dao.get(file.id) ?: error("No such file ${file.id}")
        require(cur.state == file.state) { "updateDetails must not change the state" }
        dao.update(file)
    }

    override fun apply(id: Long, event: FileEvent, now: Long, maxAttempts: Int, jitter01: Double): FileEntity =
        db.runInTransaction<FileEntity> {
            val cur = dao.get(id) ?: error("No such file $id")
            val next = FileStateMachine.transition(cur, event, now, maxAttempts, jitter01)
            dao.update(next)
            next
        }

    override fun nextInQueue(now: Long, allowBot: Boolean, allowAccount: Boolean, excludeRuleIds: Set<Long>) =
        dao.nextInQueue(now, allowBot, allowAccount, excludeRuleIds.ifEmpty { setOf(-1L) }.toList())

    override fun queueCount(now: Long, allowBot: Boolean, allowAccount: Boolean) = dao.queueCount(now, allowBot, allowAccount)
    override fun waitingAccountCount() = dao.waitingAccountCount()
    override fun earliestRetryAt() = dao.earliestRetryAt()
    override fun interrupted() = dao.interrupted()
    override fun byRuleAndStates(ruleId: Long, states: Set<FileState>) = dao.byRuleAndStates(ruleId, states.toList())
    override fun verifiedDue(ruleId: Long, now: Long, limit: Int) = dao.verifiedDue(ruleId, now, limit)
    override fun inReview(reviewId: Long) = dao.inReview(reviewId)
    override fun setReview(fileIds: List<Long>, reviewId: Long?) {
        fileIds.chunked(500).forEach { dao.setReview(it, reviewId) }
    }
    override fun stateCounts() = dao.stateCounts()
    override fun freedBytesSince(since: Long) = dao.freedBytesSince(since)
    override fun freedBytesTotal() = dao.freedBytesTotal()
    override fun uploadedCountSince(since: Long) = dao.uploadedCountSince(since)
    override fun skippedCountSince(since: Long) = dao.skippedCountSince(since)
    override fun page(ruleId: Long?, state: FileState?, cursor: Long?, limit: Int) = dao.page(ruleId, state, cursor, limit)

    override fun setDeleteAfterForRule(ruleId: Long, deleteAfter: (FileEntity) -> Long?) = db.runInTransaction {
        dao.verifiedOf(ruleId).forEach { dao.setDeleteAfter(it.id, deleteAfter(it)) }
    }
}
