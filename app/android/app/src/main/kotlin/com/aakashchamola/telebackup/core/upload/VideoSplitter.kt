package com.aakashchamola.telebackup.core.upload

import java.io.File

/** Telegram takes 2 GB a file. Parts stay well under it, and a video is cut only when it does not fit in one. */
object SplitPlan {
    const val PART_MAX_BYTES = 1_900_000_000L
    /** An album holds 10 items, so a video that would need more than 10 parts is left alone. */
    const val MAX_PARTS = 10
    private val splittable = setOf("mp4", "m4v", "mov", "3gp")

    fun canSplit(displayName: String): Boolean = displayName.substringAfterLast('.', "").lowercase() in splittable

    /** How many parts a file of [sizeBytes] is cut into (1 = it fits whole). */
    fun partsNeeded(sizeBytes: Long, maxPart: Long = PART_MAX_BYTES): Int = ((sizeBytes + maxPart - 1) / maxPart).toInt().coerceAtLeast(1)

    /** A part is ended at the first keyframe after it reaches this size, so that all parts come out about equal. */
    fun targetPartBytes(sizeBytes: Long, parts: Int, maxPart: Long = PART_MAX_BYTES): Long =
        minOf(sizeBytes / parts.coerceAtLeast(1), maxPart - minOf(30_000_000L, maxPart / 10)).coerceAtLeast(1)

    fun partName(displayName: String, index: Int, parts: Int): String {
        val base = displayName.substringBeforeLast('.', displayName)
        val ext = displayName.substringAfterLast('.', "mp4")
        return "$base (part ${index + 1} of $parts).$ext"
    }
}

sealed class SplitResult {
    data class Parts(val files: List<File>) : SplitResult()
    data class Failed(val reason: String) : SplitResult()
}

/** Cuts a video into parts at keyframes, without re-encoding, so nothing is lost in quality. */
interface VideoSplitter {
    /** Writes the parts into [outDir]. [onProgress] gets bytes read so far and the total. The caller deletes the parts when done. */
    suspend fun split(source: File, maxPartBytes: Long, outDir: File, onProgress: (done: Long, total: Long) -> Unit): SplitResult
}
