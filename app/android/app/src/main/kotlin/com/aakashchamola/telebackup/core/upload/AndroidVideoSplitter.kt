package com.aakashchamola.telebackup.core.upload

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import com.aakashchamola.telebackup.core.clean.ScratchFiles
import com.aakashchamola.telebackup.core.log.Tlog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer

/**
 * Cuts an MP4/MOV into parts with Android's MediaExtractor and MediaMuxer: the compressed frames are copied as they are,
 * and each part starts on a keyframe, so every part plays by itself. A new part starts at the first video keyframe after the
 * current one reached its share of the size. Only video and audio tracks are kept.
 */
class AndroidVideoSplitter : VideoSplitter {
    override suspend fun split(source: File, maxPartBytes: Long, outDir: File, onProgress: (Long, Long) -> Unit): SplitResult =
        withContext(Dispatchers.IO) {
            val total = source.length()
            val parts = SplitPlan.partsNeeded(total, maxPartBytes)
            if (parts < 2) return@withContext SplitResult.Parts(listOf(source))
            if (parts > SplitPlan.MAX_PARTS) return@withContext SplitResult.Failed("it would need more than ${SplitPlan.MAX_PARTS} parts")
            outDir.mkdirs()
            if (outDir.usableSpace < total + 200_000_000L) return@withContext SplitResult.Failed("not enough free space on the phone to cut it")
            val target = SplitPlan.targetPartBytes(total, parts, maxPartBytes)
            val made = ArrayList<File>()
            val extractor = MediaExtractor()
            var muxer: MediaMuxer? = null
            try {
                extractor.setDataSource(source.absolutePath)
                val isVideo = HashMap<Int, Boolean>()
                for (i in 0 until extractor.trackCount) {
                    val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/")) { isVideo[i] = true; extractor.selectTrack(i) }
                    else if (mime.startsWith("audio/")) { isVideo[i] = false; extractor.selectTrack(i) }
                }
                if (isVideo.values.none { it }) return@withContext SplitResult.Failed("it has no video track")
                val rotation = rotationOf(source)

                var buf = ByteBuffer.allocate(4 * 1024 * 1024)
                val info = MediaCodec.BufferInfo()
                var partIndex = -1
                var partBytes = 0L
                var baseUs = 0L
                var read = 0L
                var samples = 0
                var map = HashMap<Int, Int>()

                fun closePart() {
                    muxer?.let { runCatching { it.stop() }; runCatching { it.release() } }
                    muxer = null
                }
                fun openPart(timeUs: Long) {
                    closePart()
                    partIndex++
                    val f = File(outDir, "part${partIndex + 1}-${source.name}")
                    made += f
                    val m = MediaMuxer(f.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                    m.setOrientationHint(rotation)
                    map = HashMap()
                    for (i in isVideo.keys.sorted()) map[i] = m.addTrack(extractor.getTrackFormat(i))
                    m.start()
                    muxer = m
                    baseUs = timeUs
                    partBytes = 0
                }

                while (true) {
                    var size = extractor.readSampleData(buf, 0)
                    if (size < 0) break
                    val track = extractor.sampleTrackIndex
                    val timeUs = extractor.sampleTime
                    val sync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                    val keyframe = isVideo[track] == true && sync
                    if (muxer == null || (keyframe && partBytes >= target && partIndex < parts - 1)) openPart(timeUs)
                    info.set(0, size, maxOf(0L, timeUs - baseUs), if (sync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    muxer!!.writeSampleData(map.getValue(track), buf, info)
                    partBytes += size
                    read += size
                    if (++samples % 400 == 0) {
                        currentCoroutineContext().ensureActive()
                        onProgress(read, total)
                    }
                    extractor.advance()
                    buf.clear()
                }
                closePart()
                onProgress(total, total)
                val tooBig = made.firstOrNull { it.length() >= maxPartBytes + 40_000_000L }
                if (made.size < 2) return@withContext SplitResult.Failed("it could not be cut into parts")
                if (tooBig != null) return@withContext SplitResult.Failed("a part came out too big to send")
                SplitResult.Parts(made.toList())
            } catch (e: kotlinx.coroutines.CancellationException) {
                made.forEach(ScratchFiles::remove); throw e
            } catch (e: Exception) {
                Tlog.w("split failed: ${e.javaClass.simpleName}")
                made.forEach(ScratchFiles::remove)
                SplitResult.Failed("this video's format cannot be cut here")
            } finally {
                muxer?.let { runCatching { it.release() } }
                extractor.release()
            }
        }

    private fun rotationOf(f: File): Int {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(f.absolutePath)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        } catch (e: Exception) { 0 } finally { runCatching { r.release() } }
    }
}
