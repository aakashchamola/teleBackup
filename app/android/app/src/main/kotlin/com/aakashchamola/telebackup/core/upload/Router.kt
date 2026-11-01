package com.aakashchamola.telebackup.core.upload

import com.aakashchamola.telebackup.core.model.FileKind
import com.aakashchamola.telebackup.core.model.Route
import com.aakashchamola.telebackup.core.model.SendAs
import com.aakashchamola.telebackup.core.model.UploadAs

sealed class RouteDecision {
    data class Go(val route: Route, val sendAs: SendAs, val note: String? = null) : RouteDecision()
    data class Skip(val reason: String) : RouteDecision()
}

data class RouterLimits(
    val botMaxBytes: Long = 52_428_800L,       // strictly less than this goes by bot
    val botPhotoMaxBytes: Long = 10_485_760L,  // photo as media limit for bots
    val accountMaxBytes: Long = 2_000_000_000L,
)

/** Picks the Telegram route and the send form for one file (docs/TELEGRAM.md section 1). */
object Router {
    private val oddPhotoTypes = setOf("heic", "heif", "dng", "gif", "webp")

    fun decide(
        sizeBytes: Long,
        kind: FileKind,
        uploadAs: UploadAs,
        displayName: String,
        width: Int?,
        height: Int?,
        limits: RouterLimits = RouterLimits(),
    ): RouteDecision {
        if (sizeBytes >= limits.accountMaxBytes) {
            return RouteDecision.Skip("Too big for Telegram (over 2 GB)")
        }
        val route = if (sizeBytes < limits.botMaxBytes) Route.BOT else Route.ACCOUNT
        if (uploadAs == UploadAs.ORIGINAL) return RouteDecision.Go(route, SendAs.DOCUMENT)
        return when (kind) {
            FileKind.VIDEO -> RouteDecision.Go(route, SendAs.VIDEO)
            FileKind.PHOTO -> {
                val ext = displayName.substringAfterLast('.', "").lowercase()
                when {
                    ext in oddPhotoTypes -> RouteDecision.Go(route, SendAs.DOCUMENT, "odd photo type")
                    sizeBytes > limits.botPhotoMaxBytes -> RouteDecision.Go(route, SendAs.DOCUMENT, "too big for a photo")
                    !photoShapeOk(width, height) -> RouteDecision.Go(route, SendAs.DOCUMENT, "photo shape not allowed")
                    else -> RouteDecision.Go(route, SendAs.PHOTO)
                }
            }
        }
    }

    /** sendPhoto needs width + height <= 10000 and aspect ratio <= 20. Unknown size is allowed. */
    private fun photoShapeOk(w: Int?, h: Int?): Boolean {
        if (w == null || h == null || w <= 0 || h <= 0) return true
        if (w + h > 10_000) return false
        val ratio = maxOf(w, h).toDouble() / minOf(w, h)
        return ratio <= 20.0
    }
}
