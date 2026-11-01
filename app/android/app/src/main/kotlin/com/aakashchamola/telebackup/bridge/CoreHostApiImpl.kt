package com.aakashchamola.telebackup.bridge

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import com.aakashchamola.telebackup.core.control.ControlActions
import com.aakashchamola.telebackup.core.db.FileEntity
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.log.Diagnostics
import com.aakashchamola.telebackup.core.log.DiagnosticsInput
import com.aakashchamola.telebackup.core.log.Tlog
import com.aakashchamola.telebackup.core.model.EventKind
import com.aakashchamola.telebackup.core.model.FileEvent
import com.aakashchamola.telebackup.core.rules.*
import com.aakashchamola.telebackup.core.secrets.SecretNames
import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.telegram.bot.ApiResult
import com.aakashchamola.telebackup.core.telegram.bot.setupMessage
import com.aakashchamola.telebackup.core.upload.FaultInjector
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import com.aakashchamola.telebackup.core.model.FileState as CoreFileState
import com.aakashchamola.telebackup.core.model.StartMode as CoreStartMode
import com.aakashchamola.telebackup.core.model.MediaTypes as CoreMediaTypes
import com.aakashchamola.telebackup.core.model.UploadAs as CoreUploadAs
import com.aakashchamola.telebackup.core.model.RuleMode as CoreRuleMode
import com.aakashchamola.telebackup.core.settings.SettingsRepository

/** Implements what the screens can ask of the core. Thin on purpose: every rule lives in `core/`. */
class CoreHostApiImpl(private val context: Context) : CoreHostApi {
    private val sl get() = ServiceLocator.get(context)
    private val now get() = sl.clock.now()
    private val lastChecks = HashMap<Long, com.aakashchamola.telebackup.core.telegram.bot.GroupCheck>()

    private val accountMissing = "Logging in to a Telegram account is not in this build yet. Big videos wait."

    private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: FlutterError) {
            throw e
        } catch (e: RuleException) {
            throw FlutterError("VALIDATION", e.problems.firstOrNull()?.message ?: "Check the rule.", e.problems.firstOrNull()?.field)
        } catch (e: RulesExport.BadFile) {
            throw FlutterError("VALIDATION", e.message ?: "That file did not work.")
        } catch (e: Exception) {
            Tlog.e("bridge call failed", e)
            throw FlutterError("INTERNAL", "Something went wrong. Try again.")
        }
    }

    private fun tg(e: TgError): Nothing = when (e) {
        TgError.Network -> throw FlutterError("NO_NETWORK", e.setupMessage())
        is TgError.FloodWait -> throw FlutterError("FLOOD_WAIT", e.setupMessage(), e.seconds.toString())
        else -> throw FlutterError("TELEGRAM", e.setupMessage())
    }

    // ----- status and controls -----

    override suspend fun getStatus(): Status = io { sl.statusHub.refresh().toBridge() }
    override suspend fun pause() = io { ControlActions.pause(sl) }
    override suspend fun resume() = io { ControlActions.resume(sl) }
    override suspend fun delay(minutes: Long) = io { ControlActions.delay(sl, minutes.toInt()) }
    override suspend fun scanNow(ruleId: Long?) = io { sl.scheduler.enqueueScanNow(ruleId) }
    override suspend fun uploadNow(mobileDataOnce: Boolean) = io {
        if (mobileDataOnce) { sl.settings.mobileOnceUntilEmpty = true; sl.scheduler.reenqueueUploadWithNewConstraint() }
        else sl.scheduler.enqueueUpload()
    }

    // ----- rules -----

    private fun stats(r: RuleEntity): RuleStats {
        val counts = sl.fileStore.stateCounts().filter { it.ruleId == r.id }
        fun n(vararg s: CoreFileState) = counts.filter { it.state in s }.sumOf { it.count }.toLong()
        fun b(vararg s: CoreFileState) = counts.filter { it.state in s }.sumOf { it.bytes }
        val due = sl.fileStore.verifiedDue(r.id, now, 100_000).size.toLong()
        val topicMissing = r.topicId?.let { sl.topicStore.get(it)?.missing } ?: false
        return RuleStats(
            ruleId = r.id, queued = n(CoreFileState.QUEUED, CoreFileState.FAILED, CoreFileState.UPLOADING),
            backedUp = n(CoreFileState.VERIFIED, CoreFileState.UPLOADED), backedUpBytes = b(CoreFileState.VERIFIED, CoreFileState.UPLOADED),
            waitingDelete = due, deleted = n(CoreFileState.DELETED), freedBytes = b(CoreFileState.DELETED), skipped = n(CoreFileState.SKIPPED),
            deleteBlockedReason = sl.settings.deletesBlockedReason, topicMissing = topicMissing,
        )
    }

    override suspend fun listRules(): List<RuleWithStats> = io { sl.rules.active().map { RuleWithStats(it.toBridge(), stats(it)) } }

    override suspend fun getRule(id: Long): RuleWithStats = io {
        val r = sl.rules.get(id) ?: throw FlutterError("VALIDATION", "That rule is gone.")
        RuleWithStats(r.toBridge(), stats(r))
    }

    override suspend fun saveRule(rule: Rule): Long = io {
        val existing = rule.id?.let { sl.rules.get(it) }
        var topicId = rule.topicId
        val newTopic = rule.newTopicName?.trim()?.takeIf { it.isNotEmpty() }
        if (newTopic != null) {
            if (sl.secrets.get(SecretNames.BOT_TOKEN) == null || sl.settings.chatId == null)
                throw FlutterError("NOT_SET_UP", "Topics can be made once Telegram is connected.")
            when (val t = sl.botSetup.createTopic(newTopic)) {
                is ApiResult.Ok -> topicId = t.value.threadId
                is ApiResult.Err -> tg(t.error)
            }
        }
        val entity = rule.toEntity(existing, now, topicId)
        val folderOk = sl.mediaSource.folderExists(RuleValidator.normalizeFolder(entity.folderPath))
        val saved = sl.rules.save(entity, folderOk)
        sl.scheduler.enqueueScanNow(saved.id)
        saved.id
    }

    override suspend fun setRuleEnabled(id: Long, enabled: Boolean) = io { sl.rules.setEnabled(id, enabled) }
    override suspend fun deleteRule(id: Long) = io { sl.rules.softDelete(id) }

    override suspend fun previewRule(rule: Rule): BacklogPreview = io {
        val p = sl.scanner.preview(rule.toEntity(null, now, rule.topicId).copy(startDate = previewStart(rule)))
        BacklogPreview(p.count.toLong(), p.bytes, p.newestAt, p.oldestAt)
    }

    private fun previewStart(rule: Rule): Long? = when (rule.startMode.asCore<CoreStartMode>()) {
        CoreStartMode.TODAY -> now
        CoreStartMode.SINCE_DATE -> rule.startDate
        CoreStartMode.EVERYTHING -> null
    }

    private fun catalog() = FolderCatalog(Environment.getExternalStorageDirectory(), sl.mediaSource, sl.ruleStore)

    override suspend fun suggestedFolders(): List<FolderInfo> = io {
        catalog().suggestions().map { (_, e) -> FolderInfo(e.path, e.label, e.mediaCount.toLong(), e.usedByRule, e.isSuggestion, e.hint) }
    }

    override suspend fun listFolder(path: String): List<FolderInfo> = io {
        catalog().listFolder(path).map { FolderInfo(it.path, it.label, it.mediaCount.toLong(), it.usedByRule, false, null) }
    }

    override suspend fun listTopics(): List<Topic> = io {
        sl.settings.chatId?.let { chat -> sl.topicStore.list(chat).map { it.toBridge() } } ?: emptyList()
    }

    override suspend fun remakeTopic(ruleId: Long): Topic = io {
        val r = sl.rules.get(ruleId) ?: throw FlutterError("VALIDATION", "That rule is gone.")
        when (val t = sl.botSetup.createTopic(r.name)) {
            is ApiResult.Ok -> {
                r.topicId?.let { sl.topicStore.markMissing(it, true) }
                sl.ruleStore.update(r.copy(topicId = t.value.threadId, updatedAt = now))
                sl.scheduler.enqueueUpload()
                t.value.toBridge()
            }
            is ApiResult.Err -> tg(t.error)
        }
    }

    override suspend fun stopAllDeletes() = io { sl.killSwitch.stopAllDeletes(); sl.statusHub.refresh(); Unit }

    // ----- reviews -----

    private fun fileItems(files: List<FileEntity>): List<FileItem> {
        val names = HashMap<Long, String>()
        return files.map { f -> f.toBridge(names.getOrPut(f.ruleId) { sl.rules.get(f.ruleId)?.name ?: "" }, sl.settings.chatId) }
    }

    override suspend fun getReview(ruleId: Long): Review? = io {
        val rv = sl.reviewStore.waitingFor(ruleId) ?: return@io null
        val rule = sl.rules.get(ruleId)
        Review(rv.id, ruleId, rule?.name ?: "", rv.fileCount.toLong(), rv.totalBytes, fileItems(sl.fileStore.inReview(rv.id).take(500)), false)
    }

    override suspend fun previewDeletes(ruleId: Long): Review = io {
        val rule = sl.rules.get(ruleId) ?: throw FlutterError("VALIDATION", "That rule is gone.")
        val files = sl.fileStore.verifiedDue(ruleId, now, 500)
        Review(0, ruleId, rule.name, files.size.toLong(), files.sumOf { it.sizeBytes }, fileItems(files), true)
    }

    override suspend fun approveReview(reviewId: Long) = io { sl.reviews.approve(reviewId); sl.scheduler.enqueueCleanNow(reviewId) }
    override suspend fun dismissReview(reviewId: Long) = io { sl.reviews.dismiss(reviewId); sl.statusHub.refresh(); Unit }

    // ----- files and history -----

    override suspend fun listEvents(filter: HistoryFilter, search: String?, ruleId: Long?, cursor: Long?): EventPage = io {
        val kinds: Set<EventKind>? = when (filter) {
            HistoryFilter.ALL -> null
            HistoryFilter.UPLOADED -> setOf(EventKind.UPLOADED, EventKind.VERIFIED)
            HistoryFilter.DELETED -> setOf(EventKind.DELETED, EventKind.REVIEW_APPROVED)
            HistoryFilter.SKIPPED -> setOf(EventKind.SKIPPED)
            HistoryFilter.PROBLEMS -> setOf(
                EventKind.FAILED, EventKind.VERIFY_FAILED, EventKind.SKIPPED, EventKind.DELETE_DENIED, EventKind.LOGIN_EXPIRED,
                EventKind.PERMISSION_LOST, EventKind.TOPIC_MISSING, EventKind.BOT_PROBLEM, EventKind.RETRIED,
            )
        }
        val limit = 50
        val rows = sl.eventStore.page(kinds, ruleId, search, cursor, limit)
        EventPage(rows.map { EventItem(it.id, it.at, it.kind.name, it.message, it.fileId, it.ruleId, it.bytes) }, if (rows.size == limit) rows.last().id else null)
    }

    override suspend fun listFiles(ruleId: Long, state: FileState?, cursor: Long?): FilePage = io {
        val limit = 50
        val rows = sl.fileStore.page(ruleId, state?.asCore<CoreFileState>(), cursor, limit)
        FilePage(fileItems(rows), if (rows.size == limit) rows.last().id else null)
    }

    override suspend fun getFile(id: Long): FileItem = io {
        val f = sl.fileStore.get(id) ?: throw FlutterError("VALIDATION", "That file is gone.")
        fileItems(listOf(f)).single()
    }

    override suspend fun retryFile(id: Long) = io {
        sl.fileStore.apply(id, FileEvent.RetryByPerson, now)
        sl.events.add(EventKind.RETRIED, "Put back in the queue by you", fileId = id)
        sl.scheduler.enqueueUpload()
    }

    // ----- settings -----

    override suspend fun getSettings(): AppSettings = io {
        val s = sl.settings
        AppSettings(s.allowMobileData, s.delayOptionsMinutes.map { it.toLong() }, s.defaultRetentionDays.toLong(), s.setupDone, s.setupStep, sl.debugBuild)
    }

    override suspend fun setAllowMobileData(on: Boolean) = io { sl.settings.allowMobileData = on; sl.scheduler.reenqueueUploadWithNewConstraint(); Unit }

    override suspend fun setDelayOptions(minutes: List<Long>) = io {
        val m = minutes.map { it.toInt() }
        if (!SettingsRepository.isValidDelayOptions(m)) throw FlutterError("VALIDATION", "Use 1 to 4 options, each between 15 minutes and 24 hours.")
        sl.settings.delayOptionsMinutes = m
    }

    override suspend fun setDefaultRetention(days: Long) = io {
        if (days !in 1..365) throw FlutterError("VALIDATION", "Use 1 to 365 days.")
        sl.settings.defaultRetentionDays = days.toInt()
    }

    override suspend fun setSetupStep(step: String) = io { sl.settings.setupStep = step }

    override suspend fun finishSetup() = io {
        sl.settings.setupDoneAt = now
        sl.scheduler.scheduleDaily()
        sl.scheduler.enqueueScanNow(null)
    }

    override suspend fun exportRules(): String = io {
        val names = sl.settings.chatId?.let { c -> sl.topicStore.list(c).associate { it.threadId to it.name } } ?: emptyMap()
        RulesExport.export(sl.rules.exportable(), names, sl.settings, now)
    }

    override suspend fun importRules(json: String): Long = io {
        val chat = sl.settings.chatId
        val byName = chat?.let { sl.topicStore.list(it).associate { t -> t.name.lowercase() to t.threadId } } ?: emptyMap()
        val rules = RulesExport.import(json, sl.rules.active().map { it.name }, { byName[it.lowercase()] }, now)
        var n = 0L
        for (r in rules) { sl.rules.save(r); n++ }
        n
    }

    // ----- telegram -----

    override suspend fun setBotToken(token: String): BotInfo = io {
        when (val r = sl.botSetup.checkToken(token)) {
            is ApiResult.Ok -> {
                sl.secrets.put(SecretNames.BOT_TOKEN, token.trim())
                BotInfo(r.value.id, r.value.username, r.value.name)
            }
            is ApiResult.Err -> tg(r.error)
        }
    }

    override suspend fun findGroups(): List<GroupCandidate> = io {
        when (val r = sl.botSetup.findGroups()) {
            is ApiResult.Ok -> r.value.map { GroupCandidate(it.id, it.title) }
            is ApiResult.Err -> tg(r.error)
        }
    }

    private suspend fun check(chatId: Long) = when (val r = sl.botSetup.checkGroup(chatId)) {
        is ApiResult.Ok -> r.value.also { lastChecks[it.chatId] = it }
        is ApiResult.Err -> tg(r.error)
    }

    override suspend fun checkGroup(chatId: Long): GroupCheck = io {
        val c = check(chatId)
        GroupCheck(c.chatId, c.title, c.topicsOn, c.botIsAdmin, c.botCanManageTopics)
    }

    override suspend fun selectGroup(chatId: Long) = io {
        val c = check(chatId)
        if (!c.allGood) throw FlutterError("TELEGRAM", "The group is not ready yet. Check Topics and the bot's rights.")
        when (val r = sl.botSetup.selectGroup(c)) {
            is ApiResult.Ok -> Unit
            is ApiResult.Err -> tg(r.error)
        }
    }

    override suspend fun getTelegramState(): TelegramState = io {
        val s = sl.settings
        val bot = s.botId?.let { BotInfo(it, s.botUsername ?: "", "") }
        val chat = s.chatId
        val group = chat?.let { lastChecks[it]?.let { c -> GroupCheck(c.chatId, c.title, c.topicsOn, c.botIsAdmin, c.botCanManageTopics) } ?: GroupCheck(it, s.chatTitle ?: "", true, true, true) }
        TelegramState(bot = bot, group = group, account = s.accountState.toBridge(), accountName = s.accountName)
    }

    override suspend fun accountStart(apiId: Long, apiHash: String) = io { throw FlutterError("INTERNAL", accountMissing) }
    override suspend fun accountPhone(phone: String) = io { throw FlutterError("INTERNAL", accountMissing) }
    override suspend fun accountCode(code: String) = io { throw FlutterError("INTERNAL", accountMissing) }
    override suspend fun accountPassword(password: String) = io { throw FlutterError("INTERNAL", accountMissing) }
    override suspend fun accountResendCode() = io { throw FlutterError("INTERNAL", accountMissing) }
    override suspend fun accountLogout() = io {
        sl.secrets.remove(SecretNames.API_ID); sl.secrets.remove(SecretNames.API_HASH)
        sl.settings.accountState = com.aakashchamola.telebackup.core.model.AccountValue.NONE
        sl.settings.accountName = null
    }

    override suspend fun createSuggestedRules(suggestionPaths: List<String>, startMode: StartMode, startDate: Long?): Long = io {
        if (sl.secrets.get(SecretNames.BOT_TOKEN) == null || sl.settings.chatId == null)
            throw FlutterError("NOT_SET_UP", "Connect Telegram first.")
        var made = 0L
        val sm = startMode.asCore<CoreStartMode>()
        for (id in suggestionPaths) {
            val s = FolderCatalog.KNOWN.firstOrNull { it.id == id } ?: continue
            val topicId = when (val t = sl.botSetup.createTopic(s.label)) {
                is ApiResult.Ok -> t.value.threadId
                is ApiResult.Err -> tg(t.error)
            }
            val name = uniqueName(s.label)
            val rule = RuleEntity(
                name = name, folderPath = s.folder, mediaTypes = s.types.asCore<CoreMediaTypes>(), topicId = topicId,
                uploadAs = if (s.folder.startsWith("DCIM/")) CoreUploadAs.ORIGINAL else CoreUploadAs.MEDIA, mode = CoreRuleMode.UPLOAD_ONLY,
                retentionDays = sl.settings.defaultRetentionDays, startMode = sm, startDate = startDate, enabled = true, dryRun = true,
            )
            sl.rules.save(rule)
            made++
            delay(1200)   // pace topic creation: Telegram limits how fast a bot may create them
        }
        sl.scheduler.enqueueScanNow(null)
        made
    }

    private fun uniqueName(base: String): String {
        val used = sl.rules.active().map { it.name.lowercase() }.toSet()
        if (base.lowercase() !in used) return base
        var n = 2
        while ("$base ($n)".lowercase() in used) n++
        return "$base ($n)"
    }

    // ----- phone -----

    override suspend fun getPermissions(): Permissions = io {
        val p = sl.permissions.state()
        Permissions(p.notifications, p.allFiles, p.batteryExempt, p.mediaRead, MakerGuide.forManufacturer(Build.MANUFACTURER))
    }

    private fun launch(i: Intent) { context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }

    override suspend fun openAllFilesSettings() = io {
        launch(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${context.packageName}")))
    }

    override suspend fun requestBatteryExemption() = io {
        launch(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")))
    }

    override suspend fun openNotificationSettings() = io {
        launch(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
    }

    // ----- help -----

    override suspend fun diagnostics(): String = io {
        val problems = sl.eventStore.page(
            setOf(EventKind.FAILED, EventKind.VERIFY_FAILED, EventKind.SKIPPED, EventKind.DELETE_DENIED, EventKind.LOGIN_EXPIRED,
                EventKind.PERMISSION_LOST, EventKind.TOPIC_MISSING, EventKind.BOT_PROBLEM, EventKind.RUN_STOPPED), null, null, null, 50,
        )
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        Diagnostics.build(
            DiagnosticsInput(
                appVersion = "${info.versionName} (${info.longVersionCode})", androidVersion = "${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})",
                phoneModel = "${Build.MANUFACTURER} ${Build.MODEL}", permissions = sl.permissions.state(),
                lastScanAt = sl.settings.lastScanAt, lastUploadAt = sl.settings.lastUploadAt, lastCleanAt = sl.settings.lastCleanAt,
                lastStopReason = sl.settings.lastStopReason, counts = sl.fileStore.stateCounts(), recentProblems = problems,
                workStates = workStates(), setupDone = sl.settings.setupDone, accountState = sl.settings.accountState.name.lowercase(),
                deletesBlockedReason = sl.settings.deletesBlockedReason,
            ),
        )
    }

    private fun workStates(): List<String> = try {
        val wm = androidx.work.WorkManager.getInstance(context)
        listOf("daily", "scan-now", "upload", "resume-at", "clean-now", "retry-at").map { name ->
            val infos = wm.getWorkInfosForUniqueWork(name).get()
            "$name: " + (infos.lastOrNull()?.state?.name?.lowercase() ?: "not scheduled")
        }
    } catch (e: Exception) { emptyList() }

    // ----- debug builds only -----

    override suspend fun devCommand(command: String, argument: String?): String = io {
        if (!sl.debugBuild) throw FlutterError("INTERNAL", "Not available.")
        when (command) {
            "timeWarp" -> { sl.settings.timeWarp = argument == "on"; "Time warp ${if (sl.settings.timeWarp) "on" else "off"}" }
            "scan" -> { sl.scheduler.enqueueScanNow(null); "Scan queued" }
            "upload" -> { sl.scheduler.enqueueUpload(); "Upload queued" }
            "clean" -> { sl.scheduler.enqueueCleanNow(null); "Clean queued" }
            "fault" -> { FaultInjector.arm(argument); "Next send will fail: ${argument ?: "none"}" }
            "addTopic" -> {
                val (id, name) = (argument ?: "").split("|").let { it.getOrNull(0)?.trim()?.toLongOrNull() to (it.getOrNull(1)?.trim() ?: "Topic") }
                val chat = sl.settings.chatId ?: throw FlutterError("NOT_SET_UP", "Choose a group first.")
                if (id == null) throw FlutterError("VALIDATION", "Use: threadId|name")
                sl.topicStore.upsert(com.aakashchamola.telebackup.core.db.TopicEntity(id, chat, name, null, com.aakashchamola.telebackup.core.model.TopicSource.CREATED_BY_APP, false, now))
                "Topic $id added"
            }
            "setChat" -> { sl.settings.chatId = argument?.trim()?.toLongOrNull(); "Chat set" }
            "queue" -> sl.fileStore.page(null, null, null, 200).filter { !it.state.terminal }.joinToString("\n") { "${it.id} ${it.state} ${it.route} ${it.displayName}" }.ifEmpty { "Queue is empty" }
            "wipe" -> { sl.db.clearAllTables(); sl.secrets.clearAll(); "Wiped" }
            else -> throw FlutterError("VALIDATION", "Unknown command")
        }
    }
}

/** Which phone makers need extra steps to keep a background job alive (filled in M6). */
object MakerGuide {
    private val risky = mapOf(
        "samsung" to "samsung", "xiaomi" to "xiaomi", "redmi" to "xiaomi", "poco" to "xiaomi", "oppo" to "oppo", "realme" to "oppo",
        "oneplus" to "oppo", "vivo" to "vivo", "iqoo" to "vivo", "huawei" to "huawei", "honor" to "huawei", "motorola" to "motorola",
        "google" to "pixel",
    )
    fun forManufacturer(m: String): String? = risky[m.lowercase()]
}
