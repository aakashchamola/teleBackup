package com.aakashchamola.telebackup.core.clean

import android.content.ContentUris
import android.content.Context
import android.media.MediaScannerConnection
import android.provider.MediaStore
import com.aakashchamola.telebackup.core.db.FileEntity
import java.io.File

sealed class DeleteOutcome {
    data class Deleted(val bytes: Long) : DeleteOutcome()
    data class Failed(val reason: String) : DeleteOutcome()
}

/**
 * The ONLY place in the app that removes a file from the phone. A test scans the source and
 * fails if a delete call appears anywhere else (docs/TESTING.md). Callers must hold a
 * permit from the delete gate before they get here.
 */
interface FileDeleter {
    fun removeFromPhone(file: FileEntity): DeleteOutcome
}

/**
 * Cleans up the app's OWN scratch files: the parts of a video cut for Telegram, kept in cache/split. It refuses any path
 * outside that folder, so it can never reach the person's photos and videos (those only go through [FileDeleter]).
 */
object ScratchFiles {
    private fun ok(f: File): Boolean {
        val p = f.absolutePath.replace("\\", "/")
        return p.contains("/cache/split")
    }
    fun remove(f: File) { if (ok(f)) f.delete() }
    fun clear(dir: File) { if (ok(dir)) dir.deleteRecursively() }
}

class AndroidFileDeleter(private val context: Context) : FileDeleter {
    override fun removeFromPhone(file: FileEntity): DeleteOutcome {
        val f = File(file.path)
        if (!f.exists()) return DeleteOutcome.Failed("file is already gone")
        var removed = f.delete()
        if (!removed && file.mediaStoreId != null) {
            // Fall back to MediaStore, which can remove media this app does not own when it has all-files access.
            val uri = ContentUris.withAppendedId(
                if (file.kind == com.aakashchamola.telebackup.core.model.FileKind.VIDEO)
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                file.mediaStoreId,
            )
            removed = runCatching { context.contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
        }
        if (f.exists()) return DeleteOutcome.Failed("the phone refused to delete it")
        // tell MediaStore so the gallery does not show a ghost
        MediaScannerConnection.scanFile(context, arrayOf(file.path), null, null)
        return DeleteOutcome.Deleted(file.sizeBytes)
    }
}
