package com.aakashchamola.telebackup

import android.os.Environment
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.scan.AndroidDocumentClassifier
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Looks at the photos of one folder (argument `folder`, default DCIM/Camera) with the document detector and logs what it
 * would call a document (tag DOCPROBE). Reads photos only; changes nothing and sends nothing anywhere.
 */
@RunWith(AndroidJUnit4::class)
class DocumentProbeTest {
    @Test
    fun probe() {
        val args = InstrumentationRegistry.getArguments()
        val folder = args.getString("folder") ?: "DCIM/Camera"
        val dir = File(Environment.getExternalStorageDirectory(), folder)
        assumeTrue("no such folder", dir.isDirectory)
        val photos = dir.listFiles { f -> f.isFile && f.extension.lowercase() in setOf("jpg", "jpeg", "png", "webp") }.orEmpty().sortedBy { it.lastModified() }
        val limit = args.getString("limit")?.toIntOrNull() ?: photos.size
        val classifier = AndroidDocumentClassifier()
        var docs = 0; var ocr = 0; var n = 0
        val t0 = System.currentTimeMillis()
        for (f in photos.take(limit)) {
            val s = runCatching { classifier.score(f.absolutePath) }.getOrNull() ?: continue
            n++
            if (s.ocrRan) ocr++
            if (s.isDocument) docs++
            Log.i("DOCPROBE", "ALL|${f.name}|${if (s.isDocument) "DOC" else "no"}|paper=${"%.2f".format(s.paperShare)}|chars=${s.characters}|text=${"%.2f".format(s.textShare)}|lab=${"%.2f".format(s.paperLabel)}|${s.labels}")
            if (n % 100 == 0) Log.i("DOCPROBE", "progress $n of ${minOf(limit, photos.size)}")
        }
        Log.i("DOCPROBE", "SUMMARY folder=$folder photos=$n ocrRan=$ocr documents=$docs seconds=${(System.currentTimeMillis() - t0) / 1000}")
    }
}
