package com.aakashchamola.telebackup.core.db

import androidx.room.*
import com.aakashchamola.telebackup.core.model.EventKind
import com.aakashchamola.telebackup.core.model.FileState

@Dao
interface RuleDao {
    @Query("SELECT * FROM rules WHERE id = :id") fun get(id: Long): RuleEntity?
    @Query("SELECT * FROM rules WHERE deletedAt IS NULL ORDER BY id") fun active(): List<RuleEntity>
    @Query("SELECT * FROM rules ORDER BY id") fun all(): List<RuleEntity>
    @Insert fun insert(rule: RuleEntity): Long
    @Update fun update(rule: RuleEntity)
}

@Dao
interface TopicDao {
    @Query("SELECT * FROM topics WHERE threadId = :threadId") fun get(threadId: Long): TopicEntity?
    @Query("SELECT * FROM topics WHERE chatId = :chatId ORDER BY createdAt") fun list(chatId: Long): List<TopicEntity>
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun upsert(topic: TopicEntity)
    @Query("UPDATE topics SET missing = :missing WHERE threadId = :threadId") fun markMissing(threadId: Long, missing: Boolean)
}

@Dao
interface FileDao {
    @Query("SELECT * FROM files WHERE id = :id") fun get(id: Long): FileEntity?

    @Query("SELECT * FROM files WHERE ruleId = :ruleId AND path = :path AND sizeBytes = :size AND modifiedAt = :modifiedAt LIMIT 1")
    fun find(ruleId: Long, path: String, size: Long, modifiedAt: Long): FileEntity?

    @Query("SELECT * FROM files WHERE ruleId = :ruleId AND path = :path") fun findByPath(ruleId: Long, path: String): List<FileEntity>

    @Insert(onConflict = OnConflictStrategy.IGNORE) fun insertAll(files: List<FileEntity>): List<Long>
    @Update fun update(file: FileEntity)

    @Query(
        """SELECT f.* FROM files f INNER JOIN rules r ON r.id = f.ruleId
           WHERE r.enabled = 1 AND r.deletedAt IS NULL AND f.ruleId NOT IN (:exclude)
             AND ((f.state = 'QUEUED' AND (f.nextAttemptAt IS NULL OR f.nextAttemptAt <= :now))
               OR (f.state = 'FAILED' AND f.nextAttemptAt <= :now))
             AND ((f.route = 'ACCOUNT' AND :allowAccount = 1) OR ((f.route = 'BOT' OR f.route IS NULL) AND :allowBot = 1))
           ORDER BY f.takenAt ASC, f.id ASC LIMIT 1""",
    )
    fun nextInQueue(now: Long, allowBot: Boolean, allowAccount: Boolean, exclude: List<Long>): FileEntity?

    @Query(
        """SELECT COUNT(*) AS count, COALESCE(SUM(f.sizeBytes), 0) AS bytes FROM files f INNER JOIN rules r ON r.id = f.ruleId
           WHERE r.enabled = 1 AND r.deletedAt IS NULL
             AND (f.state = 'QUEUED' OR (f.state = 'FAILED' AND f.nextAttemptAt <= :now))
             AND ((f.route = 'ACCOUNT' AND :allowAccount = 1) OR ((f.route = 'BOT' OR f.route IS NULL) AND :allowBot = 1))""",
    )
    fun queueCount(now: Long, allowBot: Boolean, allowAccount: Boolean): QueueCount

    @Query(
        """SELECT * FROM files WHERE ruleId = :ruleId AND state = 'QUEUED' AND (nextAttemptAt IS NULL OR nextAttemptAt <= :now)
           AND (route = 'BOT' OR route IS NULL) AND sendAs IN (:kindA, :kindB) AND takenAt >= :from AND takenAt < :to
           AND ((:topicId IS NULL AND topicId IS NULL) OR topicId = :topicId) AND id != :exceptId
           ORDER BY takenAt ASC, id ASC LIMIT :limit""",
    )
    fun queuedSameDay(ruleId: Long, kindA: String, kindB: String, from: Long, to: Long, topicId: Long?, exceptId: Long, now: Long, limit: Int): List<FileEntity>

    @Query("SELECT COUNT(*) FROM files WHERE state = 'QUEUED' AND route = 'ACCOUNT'") fun waitingAccountCount(): Int
    @Query("SELECT MIN(nextAttemptAt) FROM files WHERE state IN ('QUEUED', 'FAILED') AND nextAttemptAt IS NOT NULL") fun earliestRetryAt(): Long?
    @Query("SELECT * FROM files WHERE state = 'UPLOADING'") fun interrupted(): List<FileEntity>
    @Query("SELECT * FROM files WHERE ruleId = :ruleId AND state IN (:states)") fun byRuleAndStates(ruleId: Long, states: List<FileState>): List<FileEntity>

    @Query("SELECT * FROM files WHERE ruleId = :ruleId AND state = 'VERIFIED' AND deleteAfter IS NOT NULL AND deleteAfter <= :now ORDER BY takenAt ASC LIMIT :limit")
    fun verifiedDue(ruleId: Long, now: Long, limit: Int): List<FileEntity>

    @Query("SELECT * FROM files WHERE reviewId = :reviewId") fun inReview(reviewId: Long): List<FileEntity>
    @Query("UPDATE files SET reviewId = :reviewId WHERE id IN (:ids)") fun setReview(ids: List<Long>, reviewId: Long?)
    @Query("SELECT ruleId AS ruleId, state AS state, COUNT(*) AS count, COALESCE(SUM(sizeBytes), 0) AS bytes FROM files GROUP BY ruleId, state")
    fun stateCounts(): List<StateCount>

    @Query("SELECT COALESCE(SUM(freedBytes), 0) FROM files WHERE state = 'DELETED' AND deletedAt >= :since") fun freedBytesSince(since: Long): Long
    @Query("SELECT COALESCE(SUM(freedBytes), 0) FROM files WHERE state = 'DELETED'") fun freedBytesTotal(): Long
    @Query("SELECT COUNT(*) FROM files WHERE uploadedAt >= :since") fun uploadedCountSince(since: Long): Int
    @Query("SELECT COUNT(*) FROM files WHERE state = 'SKIPPED' AND updatedAt >= :since") fun skippedCountSince(since: Long): Int

    @Query(
        """SELECT * FROM files WHERE (:ruleId IS NULL OR ruleId = :ruleId) AND (:state IS NULL OR state = :state)
           AND (:cursor IS NULL OR id < :cursor) ORDER BY id DESC LIMIT :limit""",
    )
    fun page(ruleId: Long?, state: FileState?, cursor: Long?, limit: Int): List<FileEntity>

    @Query("UPDATE files SET deleteAfter = :deleteAfter WHERE id = :id") fun setDeleteAfter(id: Long, deleteAfter: Long?)
    @Query("SELECT * FROM files WHERE ruleId = :ruleId AND state = 'VERIFIED'") fun verifiedOf(ruleId: Long): List<FileEntity>
}

@Dao
interface ReviewDao {
    @Query("SELECT * FROM reviews WHERE id = :id") fun get(id: Long): ReviewEntity?
    @Query("SELECT * FROM reviews WHERE ruleId = :ruleId AND status = 'WAITING' LIMIT 1") fun waitingFor(ruleId: Long): ReviewEntity?
    @Query("SELECT * FROM reviews WHERE status = 'WAITING'") fun allWaiting(): List<ReviewEntity>
    @Insert fun insert(review: ReviewEntity): Long
    @Update fun update(review: ReviewEntity)
}

@Dao
interface EventDao {
    @Insert fun insert(event: EventEntity)

    @Query(
        """SELECT * FROM events WHERE (:anyKind = 1 OR kind IN (:kinds)) AND (:ruleId IS NULL OR ruleId = :ruleId)
           AND (:search IS NULL OR message LIKE '%' || :search || '%') AND (:beforeId IS NULL OR id < :beforeId)
           ORDER BY id DESC LIMIT :limit""",
    )
    fun page(anyKind: Boolean, kinds: List<EventKind>, ruleId: Long?, search: String?, beforeId: Long?, limit: Int): List<EventEntity>

    @Query("DELETE FROM events WHERE at < :before") fun prune(before: Long): Int
    @Query("SELECT * FROM events WHERE kind = :kind ORDER BY id DESC LIMIT 1") fun lastOf(kind: EventKind): EventEntity?
    @Query("SELECT * FROM events WHERE fileId = :fileId ORDER BY id DESC LIMIT 50") fun recentFor(fileId: Long): List<EventEntity>
}

@Dao
interface SettingDao {
    @Query("SELECT value FROM settings WHERE `key` = :key") fun get(key: String): String?
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun put(setting: SettingEntity)
    @Query("DELETE FROM settings WHERE `key` = :key") fun remove(key: String)
    @Query("SELECT * FROM settings") fun all(): List<SettingEntity>
}
