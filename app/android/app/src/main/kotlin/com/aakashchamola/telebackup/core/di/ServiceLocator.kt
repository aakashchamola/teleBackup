package com.aakashchamola.telebackup.core.di

import android.content.Context
import android.content.pm.ApplicationInfo
import com.aakashchamola.telebackup.core.clean.AndroidFileDeleter
import com.aakashchamola.telebackup.core.clean.Cleaner
import com.aakashchamola.telebackup.core.clean.Reviews
import com.aakashchamola.telebackup.core.control.ControlState
import com.aakashchamola.telebackup.core.db.*
import com.aakashchamola.telebackup.core.log.EventLog
import com.aakashchamola.telebackup.core.notify.Notifier
import com.aakashchamola.telebackup.core.rules.KillSwitch
import com.aakashchamola.telebackup.core.rules.RuleRepository
import com.aakashchamola.telebackup.core.scan.AndroidMediaSource
import com.aakashchamola.telebackup.core.scan.FileDisk
import com.aakashchamola.telebackup.core.scan.FileHasher
import com.aakashchamola.telebackup.core.scan.Scanner
import com.aakashchamola.telebackup.core.secrets.KeystoreSecrets
import com.aakashchamola.telebackup.core.secrets.SecretNames
import com.aakashchamola.telebackup.core.secrets.Secrets
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.status.*
import com.aakashchamola.telebackup.core.telegram.TelegramSender
import com.aakashchamola.telebackup.core.telegram.bot.BotApi
import com.aakashchamola.telebackup.core.telegram.bot.BotSender
import com.aakashchamola.telebackup.core.telegram.bot.BotSetup
import com.aakashchamola.telebackup.core.time.Clock
import com.aakashchamola.telebackup.core.time.SystemClockImpl
import com.aakashchamola.telebackup.core.upload.*
import com.aakashchamola.telebackup.core.work.WorkScheduler

/** Plain manual wiring (no DI framework). One instance per process, made on first use. */
class ServiceLocator private constructor(val context: Context) {
    companion object {
        @Volatile private var instance: ServiceLocator? = null
        fun get(context: Context): ServiceLocator =
            instance ?: synchronized(this) { instance ?: ServiceLocator(context.applicationContext).also { instance = it } }
    }

    val clock: Clock = SystemClockImpl
    val debugBuild: Boolean = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    val db: AppDatabase by lazy { AppDatabase.open(context) }
    val ruleStore: RuleStore by lazy { RoomRuleStore(db) }
    val topicStore: TopicStore by lazy { RoomTopicStore(db) }
    val fileStore: FileStore by lazy { RoomFileStore(db) }
    val reviewStore: ReviewStore by lazy { RoomReviewStore(db) }
    val eventStore: EventStore by lazy { RoomEventStore(db) }

    val settings: SettingsRepository by lazy { SettingsRepository(RoomKeyValueStore(db)).also { it.debugBuild = debugBuild } }
    val events: EventLog by lazy { EventLog(eventStore, clock) }
    val secrets: Secrets by lazy { KeystoreSecrets.create(context) }

    val runTracker = RunTracker()
    val permissions: PermissionProbe by lazy { AndroidPermissionProbe(context) }
    val network: NetworkProbe by lazy { AndroidNetworkProbe(context) }
    val notifier: Notifier by lazy { Notifier(context, settings, runTracker, clock) }
    val scheduler: WorkScheduler by lazy { WorkScheduler(context, settings) }

    val mediaSource by lazy { AndroidMediaSource(context) }
    val scanner: Scanner by lazy { Scanner(mediaSource, fileStore, settings, events, clock) }
    val rules: RuleRepository by lazy { RuleRepository(ruleStore, fileStore, settings, events, clock) }
    val control: ControlState by lazy { ControlState(settings, events, clock, scheduler) }
    val reviews: Reviews by lazy { Reviews(ruleStore, fileStore, reviewStore, events, clock) }
    val killSwitch: KillSwitch by lazy { KillSwitch(ruleStore, fileStore, reviewStore, events, clock) }
    val statusHub: StatusHub by lazy {
        StatusHub(StatusBuilder(settings, fileStore, ruleStore, topicStore, reviewStore, runTracker, permissions, network, clock))
    }

    fun botApi(tokenProvider: () -> String? = { secrets.get(SecretNames.BOT_TOKEN) }) = BotApi(tokenProvider)
    val botSetup: BotSetup by lazy { BotSetup(settings, topicStore, clock, { secrets.get(SecretNames.BOT_TOKEN) }) { tp -> botApi(tp) } }

    /** The account (MTProto) sender, once a TDLib build is wired in. Null until then, so big files wait. */
    var accountSender: TelegramSender? = null

    private fun botSender(): TelegramSender? =
        if (secrets.get(SecretNames.BOT_TOKEN) != null) BotSender(botApi()).let { if (debugBuild) FaultySender(it) else it } else null

    fun pacer() = Pacer(clock, settings.botPacePerMinute, 3, settings.accountMinGapSeconds * 1000L)

    fun uploadLoop(progress: ProgressSink): UploadLoop = UploadLoop(
        fileStore, ruleStore, topicStore, events, settings, clock, pacer(), FileHasher(), FileDisk(),
        botSender(), accountSender, progress,
    )

    fun cleaner(): Cleaner = Cleaner(
        ruleStore, fileStore, reviewStore, events, settings, clock, FileDisk(), AndroidFileDeleter(context),
        accountVerifier, notifier,
    )

    /** The strong check through the account. Null until the account path exists, which means deletes need the bot-only decision. */
    var accountVerifier: com.aakashchamola.telebackup.core.clean.AccountVerifier? = null

    /** Updates the tracker and the notification as the upload loop reports progress. */
    fun progressSink(): ProgressSink = object : ProgressSink {
        override fun runStarted(filesTotal: Int, bytesTotal: Long) { runTracker.begin(filesTotal); statusHub.refresh() }
        override fun fileStarted(name: String, bytesTotal: Long, filesDone: Int, filesTotal: Int) {
            runTracker.currentFileName = name; runTracker.bytesTotal = bytesTotal; runTracker.bytesDone = 0
            runTracker.filesDone = filesDone; runTracker.filesTotal = filesTotal
            notifier.updateProgress(force = true); statusHub.refresh()
        }
        override fun fileProgress(name: String, bytesDone: Long, bytesTotal: Long) {
            runTracker.bytesDone = bytesDone; runTracker.bytesTotal = bytesTotal
            notifier.updateProgress()
        }
        override fun fileFinished(filesDone: Int, filesTotal: Int) {
            runTracker.filesDone = filesDone; notifier.updateProgress(force = true); statusHub.refresh()
        }
    }

    /** Raises a notification for each blocking warning (not for ones shown on Home only). */
    fun raiseAttention() {
        for (a in statusHub.refresh().attention) notifier.attention(a)
    }
}
