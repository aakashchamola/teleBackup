package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.db.EventEntity
import com.aakashchamola.telebackup.core.db.StateCount
import com.aakashchamola.telebackup.core.log.Diagnostics
import com.aakashchamola.telebackup.core.log.DiagnosticsInput
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.*
import com.aakashchamola.telebackup.core.status.Fmt
import com.aakashchamola.telebackup.core.status.PermissionState
import com.aakashchamola.telebackup.core.telegram.SendResult
import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.upload.FaultInjector
import com.aakashchamola.telebackup.core.upload.FaultySender
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.ZoneId

class FolderCatalogTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun mk(root: File, path: String, vararg files: String) {
        val d = File(root, path).also { it.mkdirs() }
        files.forEach { File(d, it).writeText("x") }
    }

    @Test fun suggestsOnlyFoldersThatExistWithCounts() {
        val root = tmp.root
        val w = World()
        mk(root, "DCIM/Camera", "a.jpg", "b.jpg", "c.mp4", "notes.txt")
        mk(root, "Pictures/Screenshots", "s1.png")
        // the fake media source answers for the counts
        w.media.folderOk = true
        w.media.add(w.photo(1, folder = "DCIM/Camera/")); w.media.add(w.photo(2, folder = "DCIM/Camera/")); w.media.add(w.video(3).copy(path = "/storage/emulated/0/DCIM/Camera/c.mp4"))
        val cat = FolderCatalog(root, object : com.aakashchamola.telebackup.core.scan.MediaSource by w.media {
            override fun folderExists(folderPath: String) = File(root, folderPath).isDirectory
        }, w.rules)
        val labels = cat.suggestions().map { it.second.label to it.second.mediaCount }
        assertThat(labels).containsAtLeast("Gallery photos" to 2, "Gallery videos" to 1)
        assertThat(labels.map { it.first }).doesNotContain("WhatsApp images")
        assertThat(labels.count { it.first == "Screenshots" }).isEqualTo(1)   // only the first existing screenshots folder
    }

    @Test fun suggestionIdsCarryTheTypes() {
        val s = Suggestion("Gallery videos", "DCIM/Camera/", MediaTypes.VIDEOS)
        assertThat(Suggestion.parse(s.id)).isEqualTo("DCIM/Camera/" to MediaTypes.VIDEOS)
        assertThat(Suggestion.parse("nonsense")).isNull()
    }

    @Test fun browsingListsFoldersOnlyAndHidesAndroidData() {
        val root = tmp.root
        mk(root, "Android/data/x"); mk(root, "Android/obb/x"); mk(root, "Android/media"); mk(root, "DCIM/Camera", "a.jpg", "b.JPG", "c.txt"); mk(root, ".hidden")
        File(root, "readme.txt").writeText("x")
        val cat = FolderCatalog(root, FakeMedia(), MemRules())
        assertThat(cat.listFolder("").map { it.label }).containsExactly("Android", "DCIM").inOrder()
        assertThat(cat.listFolder("Android").map { it.path }).containsExactly("Android/media/")
        val dcim = cat.listFolder("DCIM").single()
        assertThat(dcim.path).isEqualTo("DCIM/Camera/"); assertThat(dcim.mediaCount).isEqualTo(2)
        assertThat(cat.listFolder("nope")).isEmpty()
    }

    @Test fun usedFoldersAreNamed() {
        val rules = MemRules()
        rules.insert(Fx.rule().copy(name = "Camera rule", folderPath = "DCIM/Camera/"))
        mk(tmp.root, "DCIM/Camera", "a.jpg")
        val cat = FolderCatalog(tmp.root, FakeMedia(), rules)
        assertThat(cat.listFolder("DCIM").single().usedByRule).isEqualTo("Camera rule")
    }
}

class RulesExportTest {
    private val w = World()

    @Test fun roundTripKeepsEverythingExceptIdsAndMakesRulesSafe() {
        val r = w.rule(name = "Screenshots", mode = RuleMode.UPLOAD_AND_DELETE, topic = 7, uploadAs = UploadAs.MEDIA, days = 14)
        val json = RulesExport.export(listOf(r), mapOf(7L to "Shots"), w.settings, w.clock.now())
        assertThat(json).contains("telebackup-rules")
        assertThat(json).doesNotContain("\"id\"")
        assertThat(json).doesNotContain("chatId")
        assertThat(json).doesNotContain("token")
        val back = RulesExport.import(json, emptyList(), { if (it == "Shots") 99L else null }, w.clock.now()).single()
        assertThat(back.name).isEqualTo("Screenshots")
        assertThat(back.folderPath).isEqualTo(r.folderPath)
        assertThat(back.retentionDays).isEqualTo(14)
        assertThat(back.topicId).isEqualTo(99)
        assertThat(back.uploadAs).isEqualTo(UploadAs.MEDIA)
        // safe defaults
        assertThat(back.mode).isEqualTo(RuleMode.UPLOAD_ONLY)
        assertThat(back.enabled).isFalse()
        assertThat(back.dryRun).isTrue()
        assertThat(back.deleteWarningAcceptedAt).isNull()
    }

    @Test fun namesInUseGetANumber() {
        val r = w.rule(name = "Camera")
        val json = RulesExport.export(listOf(r, r.copy(id = 2)), emptyMap(), w.settings, 0)
        val back = RulesExport.import(json, listOf("camera"), { null }, 0)
        assertThat(back.map { it.name }).containsExactly("Camera (2)", "Camera (3)").inOrder()
    }

    @Test fun badFilesAreRefusedInPlainWords() {
        assertThrows(RulesExport.BadFile::class.java) { RulesExport.import("not json", emptyList(), { null }, 0) }
        assertThrows(RulesExport.BadFile::class.java) {
            RulesExport.import("""{"format":"other","version":1,"exportedAt":"x","settings":{},"rules":[]}""", emptyList(), { null }, 0)
        }
        val e = assertThrows(RulesExport.BadFile::class.java) {
            RulesExport.import("""{"format":"telebackup-rules","version":5,"exportedAt":"x","settings":{},"rules":[]}""", emptyList(), { null }, 0)
        }
        assertThat(e.message).contains("newer")
    }

    @Test fun importedRulesPassTheValidator() {
        val json = """{"format":"telebackup-rules","version":1,"exportedAt":"x","settings":{},"rules":[{"name":"A","folderPath":"DCIM/Camera","retentionDays":9999,"mode":"UPLOAD_AND_DELETE"}]}"""
        val r = RulesExport.import(json, emptyList(), { null }, 0).single()
        assertThat(RuleValidator.validate(r, emptyList())).isEmpty()
        assertThat(r.retentionDays).isEqualTo(365)
        assertThat(r.folderPath).isEqualTo("DCIM/Camera/")
        assertThat(r.mode).isEqualTo(RuleMode.UPLOAD_ONLY)
    }
}

class DiagnosticsTest {
    @Test fun containsFactsButNoSecrets() {
        val token = "123456789:AAH-abcdefghijklmnopqrstuvwxyz0123456"
        val input = DiagnosticsInput(
            "1.0.0 (1)", "15 (SDK 35)", "Pixel 9", PermissionState(true, false, true, true), 1_800_000_000_000L, null, null, "QUEUE_EMPTY",
            listOf(StateCount(1, FileState.VERIFIED, 3, 3_000_000), StateCount(2, FileState.VERIFIED, 1, 1_000_000), StateCount(1, FileState.QUEUED, 2, 10)),
            listOf(EventEntity(at = 1_800_000_000_000L, kind = EventKind.FAILED, message = "Telegram refused it using https://api.telegram.org/bot$token/sendPhoto, call +91 98765 43210")),
            listOf("upload: enqueued"), true, "none", "PERMISSION_LOST",
        )
        val text = Diagnostics.build(input, ZoneId.of("UTC"))
        assertThat(text).startsWith(Diagnostics.HEADER)
        assertThat(text).contains("All files access: no")
        assertThat(text).contains("verified: 4 (4 MB)")
        assertThat(text).contains("queued: 2")
        assertThat(text).contains("Deletes blocked: PERMISSION_LOST")
        assertThat(text).contains("Last scan: 15 Jan 2027")
        assertThat(text).doesNotContain(token)
        assertThat(text).doesNotContain("98765")
    }
}

class FmtTest {
    @Test fun sizes() {
        assertThat(Fmt.size(0)).isEqualTo("0 B")
        assertThat(Fmt.size(640)).isEqualTo("640 B")
        assertThat(Fmt.size(640_000)).isEqualTo("640 KB")
        assertThat(Fmt.size(412_000_000)).isEqualTo("412 MB")
        assertThat(Fmt.size(3_200_000)).isEqualTo("3.2 MB")
        assertThat(Fmt.size(1_200_000_000)).isEqualTo("1.2 GB")
        assertThat(Fmt.size(18_400_000_000)).isEqualTo("18.4 GB")
    }
    @Test fun delayLabels() {
        assertThat(Fmt.delayLabel(120)).isEqualTo("Delay 2h")
        assertThat(Fmt.delayLabel(300)).isEqualTo("Delay 5h")
        assertThat(Fmt.delayLabel(60)).isEqualTo("Delay 1h")
        assertThat(Fmt.delayLabel(45)).isEqualTo("Delay 45 min")
    }
}

class FaultInjectorTest {
    @Test fun failsOnceThenPassesThrough() = runBlocking<Unit> {
        val ok = FakeSender.ok()
        val s = FaultySender(ok)
        val j = Fx.job()
        FaultInjector.arm("429")
        val first = s.send(j) { _, _ -> } as SendResult.Failed
        assertThat(first.error).isEqualTo(TgError.FloodWait(30))
        assertThat(s.send(j) { _, _ -> }).isInstanceOf(SendResult.Sent::class.java)
        assertThat(FaultInjector.armed()).isNull()
    }
}
