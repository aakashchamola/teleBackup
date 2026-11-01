package com.aakashchamola.telebackup.core.scan

import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import android.provider.MediaStore.Files.FileColumns as F
import androidx.exifinterface.media.ExifInterface
import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.DiskFacts
import com.aakashchamola.telebackup.core.model.FileKind
import com.aakashchamola.telebackup.core.model.MediaTypes
import com.aakashchamola.telebackup.core.upload.DiskInspector
import com.aakashchamola.telebackup.core.upload.Hasher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/** Times are compared at whole-second precision, because MediaStore keeps seconds. */
internal fun File.modifiedSeconds(): Long = lastModified() / 1000 * 1000

class MediaStoreSource(private val context: Context) : MediaSource {
    private val root: File = Environment.getExternalStorageDirectory()

    override fun list(folderPath: String, includeSubfolders: Boolean, types: MediaTypes): List<MediaItem> {
        val out = ArrayList<MediaItem>()
        val mediaTypes = when (types) {
            MediaTypes.PHOTOS -> listOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE)
            MediaTypes.VIDEOS -> listOf(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
            MediaTypes.BOTH -> listOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE, MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
        }
        val like = if (includeSubfolders) escape(folderPath) + "%" else escape(folderPath)
        val selection = "(${F.MEDIA_TYPE} IN (${mediaTypes.joinToString(",")})) AND ${F.RELATIVE_PATH} LIKE ? ESCAPE '\\' " +
            "AND ${F.IS_PENDING} = 0 AND ${F.IS_TRASHED} = 0"
        val cols = arrayOf(F._ID, F.DISPLAY_NAME, F.MIME_TYPE, F.SIZE, F.DATE_MODIFIED, F.DATE_TAKEN, F.WIDTH, F.HEIGHT, F.DURATION, F.MEDIA_TYPE, F.RELATIVE_PATH)
        try {
            context.contentResolver.query(MediaStore.Files.getContentUri("external_primary"), cols, selection, arrayOf(like), null)?.use { c ->
                val iId = c.getColumnIndexOrThrow(F._ID); val iName = c.getColumnIndexOrThrow(F.DISPLAY_NAME)
                val iMime = c.getColumnIndexOrThrow(F.MIME_TYPE); val iSize = c.getColumnIndexOrThrow(F.SIZE)
                val iMod = c.getColumnIndexOrThrow(F.DATE_MODIFIED); val iTaken = c.getColumnIndexOrThrow(F.DATE_TAKEN)
                val iW = c.getColumnIndexOrThrow(F.WIDTH); val iH = c.getColumnIndexOrThrow(F.HEIGHT)
                val iDur = c.getColumnIndexOrThrow(F.DURATION); val iType = c.getColumnIndexOrThrow(F.MEDIA_TYPE)
                val iRel = c.getColumnIndexOrThrow(F.RELATIVE_PATH)
                while (c.moveToNext()) {
                    val name = c.getString(iName) ?: continue
                    val rel = c.getString(iRel) ?: continue
                    val file = File(root, rel + name)
                    val kind = if (c.getInt(iType) == F.MEDIA_TYPE_VIDEO) FileKind.VIDEO else FileKind.PHOTO
                    out += MediaItem(
                        mediaStoreId = c.getLong(iId), path = file.absolutePath, displayName = name,
                        mimeType = c.getString(iMime) ?: "application/octet-stream", sizeBytes = c.getLong(iSize).takeIf { it > 0 } ?: file.length(),   // MediaStore keeps 0 until its own scan (seen on the Moto G62)
                        modifiedAt = c.getLong(iMod) * 1000, takenAt = c.getLong(iTaken).takeIf { it > 0 },
                        width = c.getInt(iW).takeIf { it > 0 }, height = c.getInt(iH).takeIf { it > 0 },
                        durationMs = c.getLong(iDur).takeIf { it > 0 && kind == FileKind.VIDEO }, kind = kind,
                    )
                }
            }
        } catch (e: SecurityException) {
            Tlog.w("MediaStore query refused", e)
        }
        return out
    }

    override fun exists(path: String) = File(path).exists()
    override fun folderExists(folderPath: String) = File(root, folderPath).isDirectory

    private fun escape(s: String) = s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
}

/** Lists a folder directly, for places MediaStore does not index (.nomedia folders, not scanned yet). */
class FileSystemSource : MediaSource {
    private val root: File = Environment.getExternalStorageDirectory()
    private val photoExt = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp", "dng")
    private val videoExt = setOf("mp4", "mkv", "mov", "3gp", "webm", "avi", "m4v")

    override fun list(folderPath: String, includeSubfolders: Boolean, types: MediaTypes): List<MediaItem> {
        val dir = File(root, folderPath)
        if (!dir.isDirectory) return emptyList()
        val seq = if (includeSubfolders) dir.walkTopDown().maxDepth(8) else dir.walkTopDown().maxDepth(1)
        return seq.filter { it.isFile && !it.name.startsWith(".") }.mapNotNull { f ->
            val ext = f.extension.lowercase()
            val kind = when (ext) { in photoExt -> FileKind.PHOTO; in videoExt -> FileKind.VIDEO; else -> return@mapNotNull null }
            if (types == MediaTypes.PHOTOS && kind != FileKind.PHOTO) return@mapNotNull null
            if (types == MediaTypes.VIDEOS && kind != FileKind.VIDEO) return@mapNotNull null
            MediaItem(
                mediaStoreId = null, path = f.absolutePath, displayName = f.name, mimeType = mime(ext, kind), sizeBytes = f.length(),
                modifiedAt = f.modifiedSeconds(), takenAt = if (kind == FileKind.PHOTO) exifDate(f) else null,
                width = null, height = null, durationMs = null, kind = kind,
            )
        }.toList()
    }

    private fun mime(ext: String, kind: FileKind) = when (ext) {
        "jpg", "jpeg" -> "image/jpeg"; "png" -> "image/png"; "webp" -> "image/webp"; "heic" -> "image/heic"; "heif" -> "image/heif"
        "gif" -> "image/gif"; "mp4", "m4v" -> "video/mp4"; "mkv" -> "video/x-matroska"; "mov" -> "video/quicktime"
        "3gp" -> "video/3gpp"; "webm" -> "video/webm"
        else -> if (kind == FileKind.VIDEO) "video/*" else "image/*"
    }

    private fun exifDate(f: File): Long? = try {
        ExifInterface(f.absolutePath).dateTimeOriginal?.takeIf { it > 0 }
    } catch (_: Exception) { null }

    override fun exists(path: String) = File(path).exists()
    override fun folderExists(folderPath: String) = File(root, folderPath).isDirectory
}

/** MediaStore first; if it knows nothing about a folder that does have files, list the folder itself. */
class AndroidMediaSource(context: Context) : MediaSource {
    private val store = MediaStoreSource(context)
    private val fs = FileSystemSource()

    override fun list(folderPath: String, includeSubfolders: Boolean, types: MediaTypes): List<MediaItem> {
        val fromStore = store.list(folderPath, includeSubfolders, types)
        if (fromStore.isNotEmpty()) return fromStore
        val fromDisk = fs.list(folderPath, includeSubfolders, types)
        if (fromDisk.isNotEmpty()) Tlog.i("scan: MediaStore knew nothing about a folder with ${fromDisk.size} files; used the file system")
        return fromDisk
    }

    override fun exists(path: String) = store.exists(path)
    override fun folderExists(folderPath: String) = store.folderExists(folderPath)
}

class FileDisk : DiskInspector {
    override fun inspect(path: String): DiskFacts {
        val f = File(path)
        return if (f.isFile) DiskFacts(true, f.length(), f.modifiedSeconds()) else DiskFacts(false, 0, 0)
    }
}

class FileHasher : Hasher {
    override suspend fun sha256(path: String): String = withContext(Dispatchers.IO) {
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(1 shl 20)
        FileInputStream(path).use { input ->
            while (true) {
                currentCoroutineContext().ensureActive()
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        md.digest().joinToString("") { "%02x".format(it) }
    }
}
