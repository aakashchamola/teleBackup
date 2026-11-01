package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.clean.Cleaner
import com.aakashchamola.telebackup.core.clean.Reviews
import com.aakashchamola.telebackup.core.control.ControlState
import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.model.*
import com.aakashchamola.telebackup.core.rules.KillSwitch
import com.aakashchamola.telebackup.core.rules.RuleRepository
import com.aakashchamola.telebackup.core.scan.MediaItem
import com.aakashchamola.telebackup.core.scan.Scanner
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.telegram.TelegramSender
import com.aakashchamola.telebackup.core.upload.Pacer
import com.aakashchamola.telebackup.core.upload.ProgressSink
import com.aakashchamola.telebackup.core.upload.UploadLoop
import java.time.ZoneId

/** Everything wired with in-memory fakes, for the JVM tests. */
class World(botSender: TelegramSender? = null, accountSender: TelegramSender? = null) {
    val clock = FakeClock()
    val kv = MemKv()
    val settings = SettingsRepository(kv)
    val rules = MemRules()
    val files = MemFiles().also { it.rulesForQueue = rules }
    val topics = MemTopics()
    val reviews = MemReviews()
    val eventStore = MemEvents()
    val events = EventLog(eventStore, clock)
    val media = FakeMedia()
    val disk = FakeDisk()
    val hasher = FakeHasher()
    val scheduler = FakeScheduler()
    val deleter = FakeDeleter()
    val verifier = FakeAccountVerifier()
    val pacer = Pacer(clock, 15, 3, 10_000, sleep = { clock.advance(it) })
    val control = ControlState(settings, events, clock, scheduler)
    val repo = RuleRepository(rules, files, settings, events, clock)
    val scanner = Scanner(media, files, settings, events, clock, ZoneId.of("UTC"))
    val reviewsApi = Reviews(rules, files, reviews, events, clock)
    val kill = KillSwitch(rules, files, reviews, events, clock)
    var bot: TelegramSender? = botSender
    var account: TelegramSender? = accountSender
    val progressCalls = ArrayList<String>()

    init { settings.chatId = -1001L }

    fun loop(progress: ProgressSink = object : ProgressSink {}) =
        UploadLoop(files, rules, topics, events, settings, clock, pacer, hasher, disk, bot, account, progress)

    fun cleaner(allowAccountVerifier: Boolean = true) = Cleaner(
        rules, files, reviews, events, settings, clock, disk, deleter, if (allowAccountVerifier) verifier else null, null,
    )

    /** A rule saved through the repository (so start date etc. are set like the app does). */
    fun rule(
        name: String = "Test", mode: RuleMode = RuleMode.UPLOAD_ONLY, start: StartMode = StartMode.EVERYTHING,
        topic: Long? = 5, uploadAs: UploadAs = UploadAs.ORIGINAL, types: MediaTypes = MediaTypes.BOTH,
        sub: Boolean = false, dryRun: Boolean = true, days: Int = 7,
    ): RuleEntity = repo.save(
        RuleEntity(
            name = name, folderPath = "Pictures/teleBackupTest/", mediaTypes = types, topicId = topic, uploadAs = uploadAs,
            mode = mode, retentionDays = days, startMode = start, includeSubfolders = sub, dryRun = dryRun,
            deleteWarningAcceptedAt = if (mode == RuleMode.UPLOAD_AND_DELETE) clock.now() else null,
        ),
    )

    fun photo(
        n: Int, ageMs: Long = 10 * Fx.DAY, size: Long = 2_000_000, folder: String = "Pictures/teleBackupTest/",
        name: String = "IMG_$n.jpg", taken: Long? = clock.now() - ageMs,
    ) = MediaItem(
        mediaStoreId = n.toLong(), path = "/storage/emulated/0/$folder$name", displayName = name, mimeType = "image/jpeg",
        sizeBytes = size, modifiedAt = clock.now() - ageMs, takenAt = taken, width = 4000, height = 3000, durationMs = null,
        kind = FileKind.PHOTO,
    )

    fun video(n: Int, ageMs: Long = 10 * Fx.DAY, size: Long = 80_000_000) = MediaItem(
        mediaStoreId = 100L + n, path = "/storage/emulated/0/Pictures/teleBackupTest/VID_$n.mp4", displayName = "VID_$n.mp4",
        mimeType = "video/mp4", sizeBytes = size, modifiedAt = clock.now() - ageMs, takenAt = clock.now() - ageMs,
        width = 1920, height = 1080, durationMs = 60_000, kind = FileKind.VIDEO,
    )

    /** Add media, scan, and make the disk agree with every row. */
    fun scanWith(rule: RuleEntity, vararg items: MediaItem) {
        items.forEach { media.add(it) }
        scanner.scan(rule)
        syncDisk()
    }

    fun syncDisk() { files.rows.values.forEach { disk.sync(it) } }

    fun states(): Map<Long, FileState> = files.rows.mapValues { it.value.state }
    fun all(): List<FileEntity> = files.rows.values.toList()
}
