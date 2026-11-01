package com.aakashchamola.telebackup.core.db

import com.aakashchamola.telebackup.core.model.*

/** Counts of files in a state, per rule. */
data class StateCount(val ruleId: Long, val state: FileState, val count: Int, val bytes: Long)

data class QueueCount(val count: Int, val bytes: Long)

interface RuleStore {
    fun get(id: Long): RuleEntity?
    /** Rules that are not soft-deleted. */
    fun active(): List<RuleEntity>
    fun all(): List<RuleEntity>
    fun insert(rule: RuleEntity): Long
    fun update(rule: RuleEntity)
}

interface TopicStore {
    fun get(threadId: Long): TopicEntity?
    fun list(chatId: Long): List<TopicEntity>
    fun upsert(topic: TopicEntity)
    fun markMissing(threadId: Long, missing: Boolean)
}

/**
 * Files. The state of a row changes only through [apply], which runs the state machine.
 * [updateDetails] changes other fields and refuses to touch the state.
 */
interface FileStore {
    fun get(id: Long): FileEntity?
    fun find(ruleId: Long, path: String, sizeBytes: Long, modifiedAt: Long): FileEntity?
    fun findByPath(ruleId: Long, path: String): List<FileEntity>
    /** Inserts new rows; rows that collide with an existing identity are skipped. Returns how many were inserted. */
    fun insertAll(files: List<FileEntity>): Int
    fun updateDetails(file: FileEntity)
    fun apply(id: Long, event: FileEvent, now: Long, maxAttempts: Int = FileStateMachine.DEFAULT_MAX_ATTEMPTS, jitter01: Double = 0.0): FileEntity

    /** Next file to upload, oldest first, for rules that are on, on routes that can be used now. */
    fun nextInQueue(now: Long, allowBot: Boolean, allowAccount: Boolean, excludeRuleIds: Set<Long>): FileEntity?
    fun queueCount(now: Long, allowBot: Boolean, allowAccount: Boolean): QueueCount
    /** Other queued bot files of one rule taken in [from, to) with the same kind (photo or video together, or documents) and topic, oldest first. */
    fun queuedSameDay(ruleId: Long, documents: Boolean, from: Long, to: Long, topicId: Long?, exceptId: Long, now: Long, limit: Int): List<FileEntity>
    fun waitingAccountCount(): Int
    fun earliestRetryAt(): Long?
    fun interrupted(): List<FileEntity>
    fun byRuleAndStates(ruleId: Long, states: Set<FileState>): List<FileEntity>
    fun verifiedDue(ruleId: Long, now: Long, limit: Int): List<FileEntity>
    fun inReview(reviewId: Long): List<FileEntity>
    fun setReview(fileIds: List<Long>, reviewId: Long?)
    fun stateCounts(): List<StateCount>
    fun freedBytesSince(since: Long): Long
    fun freedBytesTotal(): Long
    fun uploadedCountSince(since: Long): Int
    fun skippedCountSince(since: Long): Int
    fun page(ruleId: Long?, state: FileState?, cursor: Long?, limit: Int): List<FileEntity>
    /** Sets deleteAfter on a rule's VERIFIED files (retention or mode changed). */
    fun setDeleteAfterForRule(ruleId: Long, deleteAfter: (FileEntity) -> Long?)
}

interface ReviewStore {
    fun get(id: Long): ReviewEntity?
    fun waitingFor(ruleId: Long): ReviewEntity?
    fun allWaiting(): List<ReviewEntity>
    fun insert(review: ReviewEntity): Long
    fun update(review: ReviewEntity)
}

interface EventStore {
    fun insert(event: EventEntity)
    fun page(kinds: Set<EventKind>?, ruleId: Long?, search: String?, beforeId: Long?, limit: Int): List<EventEntity>
    fun prune(before: Long): Int
    fun lastOf(kind: EventKind): EventEntity?
    fun recentFor(fileId: Long): List<EventEntity>
}

/** Plain key/value storage behind [com.aakashchamola.telebackup.core.settings.SettingsRepository]. */
interface KeyValueStore {
    fun get(key: String): String?
    fun put(key: String, value: String?)
    fun all(): Map<String, String>
}
