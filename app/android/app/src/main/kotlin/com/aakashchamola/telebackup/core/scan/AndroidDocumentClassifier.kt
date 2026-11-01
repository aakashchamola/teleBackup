package com.aakashchamola.telebackup.core.scan

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlin.math.max

/** What the detector saw in a photo. Kept so the thresholds can be tuned on real photos. */
data class DocumentScore(
    /** Share of pixels that look like paper: light and not colourful. */
    val paperShare: Double,
    /** Letters and digits the text reader found (0 when the cheap paper test already said no). */
    val characters: Int,
    /** Share of the picture covered by blocks of text. */
    val textShare: Double,
    val ocrRan: Boolean,
    /** How sure the picture labeller is that this is paper, writing or a document (0 to 1), and what it saw, for tuning. */
    val paperLabel: Double = 0.0,
    val labels: String = "",
) {
    val isDocument: Boolean get() = (ocrRan && characters >= MIN_CHARACTERS && textShare >= MIN_TEXT_SHARE) || paperLabel >= MIN_PAPER_LABEL

    companion object {
        const val MIN_PAPER_SHARE = 0.30
        const val MIN_CHARACTERS = 60
        const val MIN_TEXT_SHARE = 0.12
        const val MIN_PAPER_LABEL = 0.70   // tuned on 519 camera photos of the owner's phone, 2026-11-02 (docs/M1_FINDINGS.md)
    }
}

/**
 * Tells photos of documents and paper from other photos, on the phone (Google's offline text reader; nothing leaves the phone).
 * Two signals. The text reader (run only on photos that are mostly light and colourless, so most photos cost almost nothing):
 * real text covering a fair part of the picture. And the picture labeller: "paper", "handwriting", "document", "receipt" with
 * good confidence, which also catches handwritten notes the text reader cannot read. Either one is enough.
 */
class AndroidDocumentClassifier : DocumentClassifier {
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    private val labeler by lazy { ImageLabeling.getClient(ImageLabelerOptions.Builder().setConfidenceThreshold(0.4f).build()) }
    private val paperWords = setOf("paper", "paper product", "document", "handwriting", "receipt", "newspaper", "menu")

    override fun isDocument(path: String): Boolean = score(path).isDocument

    fun score(path: String): DocumentScore {
        val bmp = decode(path) ?: return DocumentScore(0.0, 0, 0.0, false)
        try {
            val paper = paperShare(bmp)
            val seen = Tasks.await(labeler.process(InputImage.fromBitmap(bmp, 0)))
            val label = seen.filter { it.text.lowercase() in paperWords }.maxOfOrNull { it.confidence.toDouble() } ?: 0.0
            val names = seen.sortedByDescending { it.confidence }.take(5).joinToString(",") { "${it.text}:${"%.2f".format(it.confidence)}" }
            if (paper < DocumentScore.MIN_PAPER_SHARE) return DocumentScore(paper, 0, 0.0, false, label, names)
            val text = Tasks.await(recognizer.process(InputImage.fromBitmap(bmp, 0)))
            val chars = text.text.count { it.isLetterOrDigit() }
            val area = text.textBlocks.sumOf { b -> b.boundingBox?.let { it.width().toLong() * it.height() } ?: 0L }
            return DocumentScore(paper, chars, area.toDouble() / (bmp.width.toLong() * bmp.height).coerceAtLeast(1), true, label, names)
        } finally {
            bmp.recycle()
        }
    }

    /** A copy of the photo no bigger than about 1280 px on its long side, turned upright. */
    private fun decode(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > 2000) sample *= 2
        val raw = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val turn = when (runCatching { ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (turn == 0f) return raw
        val m = android.graphics.Matrix().apply { postRotate(turn) }
        return Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true).also { if (it !== raw) raw.recycle() }
    }

    private fun paperShare(b: Bitmap): Double {
        val stepX = max(1, b.width / 64); val stepY = max(1, b.height / 64)
        var n = 0; var paper = 0
        val hsv = FloatArray(3)
        var y = 0
        while (y < b.height) {
            var x = 0
            while (x < b.width) {
                Color.colorToHSV(b.getPixel(x, y), hsv)
                n++
                if (hsv[1] < 0.28f && hsv[2] > 0.55f) paper++
                x += stepX
            }
            y += stepY
        }
        return if (n == 0) 0.0 else paper.toDouble() / n
    }
}
