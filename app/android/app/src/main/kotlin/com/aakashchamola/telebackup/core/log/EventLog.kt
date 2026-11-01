package com.aakashchamola.telebackup.core.log

import com.aakashchamola.telebackup.core.db.EventEntity
import com.aakashchamola.telebackup.core.db.EventStore
import com.aakashchamola.telebackup.core.model.EventKind
import com.aakashchamola.telebackup.core.time.Clock

/** Writes History / Diagnostics events. Messages are redacted on the way in. */
class EventLog(private val store: EventStore, private val clock: Clock) {
    fun add(kind: EventKind, message: String, ruleId: Long? = null, fileId: Long? = null, bytes: Long? = null) {
        store.insert(EventEntity(at = clock.now(), kind = kind, ruleId = ruleId, fileId = fileId, bytes = bytes,
            message = Redactor.redact(message)))
    }
}
