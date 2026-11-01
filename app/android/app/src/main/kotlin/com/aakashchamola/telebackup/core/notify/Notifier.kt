package com.aakashchamola.telebackup.core.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.aakashchamola.telebackup.MainActivity
import com.aakashchamola.telebackup.R
import com.aakashchamola.telebackup.core.clean.ReviewNotifier
import com.aakashchamola.telebackup.core.db.ReviewEntity
import com.aakashchamola.telebackup.core.db.RuleEntity
import com.aakashchamola.telebackup.core.model.ControlValue
import com.aakashchamola.telebackup.core.settings.SettingsRepository
import com.aakashchamola.telebackup.core.status.Attention
import com.aakashchamola.telebackup.core.status.AttentionKind
import com.aakashchamola.telebackup.core.status.Fmt
import com.aakashchamola.telebackup.core.status.RunTracker
import com.aakashchamola.telebackup.core.time.Clock

/** All notifications (docs/UI.md section 8). Channel ids are stable: changing them resets the person's choices. */
class Notifier(
    private val context: Context,
    private val settings: SettingsRepository,
    private val tracker: RunTracker,
    private val clock: Clock,
) : ReviewNotifier {
    companion object {
        const val CH_UPLOADS = "uploads"
        const val CH_ATTENTION = "attention"
        const val CH_REVIEWS = "reviews"
        const val ID_PROGRESS = 1
        /** Paused / delayed use their own id, because ending the foreground service removes id 1. */
        const val ID_CONTROL = 2
        const val ID_ATTENTION_BASE = 100
        const val ID_REVIEW_BASE = 1000
        const val ACTION_PAUSE = "com.aakashchamola.telebackup.PAUSE"
        const val ACTION_DELAY = "com.aakashchamola.telebackup.DELAY"
        const val ACTION_RESUME = "com.aakashchamola.telebackup.RESUME"
        const val EXTRA_MINUTES = "minutes"
        const val EXTRA_ROUTE = "route"
        const val BIG_FILE = 50_000_000L
    }

    private val nm get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    @Volatile private var lastProgressAt = 0L

    fun createChannels() {
        nm.createNotificationChannel(NotificationChannel(CH_UPLOADS, "Backup progress", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        nm.createNotificationChannel(NotificationChannel(CH_ATTENTION, "Needs your attention", NotificationManager.IMPORTANCE_DEFAULT))
        nm.createNotificationChannel(NotificationChannel(CH_REVIEWS, "Delete checks", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun openApp(route: String?, code: Int): PendingIntent {
        val i = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        route?.let { i.putExtra(EXTRA_ROUTE, it) }
        return PendingIntent.getActivity(context, code, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun action(act: String, label: String, code: Int, minutes: Int? = null): NotificationCompat.Action {
        val i = Intent(context, ControlReceiver::class.java).setAction(act)
        minutes?.let { i.putExtra(EXTRA_MINUTES, it) }
        val pi = PendingIntent.getBroadcast(context, code, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Action.Builder(0, label, pi).build()
    }

    private fun base(channel: String) = NotificationCompat.Builder(context, channel)
        .setSmallIcon(R.drawable.ic_stat_upload).setOnlyAlertOnce(true).setContentIntent(openApp("home", 1))

    /** The foreground-service notification while uploading, or "Pausing after this file...". */
    fun progress(): android.app.Notification {
        val t = tracker
        val b = base(CH_UPLOADS).setOngoing(true).setCategory(NotificationCompat.CATEGORY_PROGRESS)
        if (t.pausing) {
            return b.setContentTitle("teleBackup · Pausing...").setContentText("Finishing ${t.currentFileName ?: "this file"} first.")
                .setProgress(0, 0, true).build()
        }
        val name = t.currentFileName ?: "Starting..."
        val total = t.bytesTotal
        val done = t.bytesDone
        val big = total != null && total >= BIG_FILE && done != null
        b.setContentTitle("teleBackup · Backing up")
        if (big) {
            b.setContentText("$name · ${Fmt.size(done!!)} of ${Fmt.size(total!!)}")
            b.setProgress(100, (done * 100 / total).toInt().coerceIn(0, 100), false)
        } else {
            b.setContentText("${t.filesDone + 1} of ${t.filesTotal.coerceAtLeast(t.filesDone + 1)} · $name")
            b.setProgress(t.filesTotal.coerceAtLeast(1), t.filesDone, false)
        }
        return b.addAction(action(ACTION_PAUSE, "Pause", 10)).build()
    }

    /** Updates the progress notification at most once a second. */
    fun updateProgress(force: Boolean = false) {
        val now = clock.now()
        if (!force && now - lastProgressAt < 1000) return
        lastProgressAt = now
        notifySafely(ID_PROGRESS, progress())
    }

    /** Shows Paused / Paused until, or removes the notification when nothing is held (service stopped). */
    fun showControlState(waiting: Int) {
        when (settings.controlState) {
            ControlValue.PAUSED -> {
                val opts = settings.delayOptionsMinutes.take(2)
                val b = base(CH_UPLOADS).setOngoing(false).setContentTitle("teleBackup · Paused").setContentText("$waiting file${if (waiting == 1) "" else "s"} waiting")
                opts.forEachIndexed { i, m -> b.addAction(action(ACTION_DELAY, Fmt.delayLabel(m), 20 + i, m)) }
                b.addAction(action(ACTION_RESUME, "Resume", 30))
                notifySafely(ID_CONTROL, b.build())
            }
            ControlValue.DELAYED -> {
                val until = settings.delayedUntil ?: clock.now()
                val b = base(CH_UPLOADS).setOngoing(false).setContentTitle("teleBackup · Paused until ${Fmt.clock(until)}").setContentText("Resumes by itself")
                    .addAction(action(ACTION_RESUME, "Resume now", 31))
                notifySafely(ID_CONTROL, b.build())
            }
            ControlValue.RUNNING -> cancelControl()
        }
    }

    fun cancelProgress() { nm.cancel(ID_PROGRESS) }
    fun cancelControl() { nm.cancel(ID_CONTROL) }

    // ----- things only the person can fix -----

    fun attention(a: Attention) {
        val (title, route) = when (a.kind) {
            AttentionKind.LOGIN_EXPIRED -> "Telegram account logged out" to "login"
            AttentionKind.ALL_FILES_LOST -> "teleBackup can't reach your folders" to "perm:files"
            AttentionKind.BOT_PROBLEM -> "teleBackup can't post to your group" to "telegram"
            AttentionKind.TOPIC_MISSING -> "A topic was deleted" to "rule:${a.ruleId ?: 0}"
            else -> return   // other warnings are shown on Home only
        }
        val n = base(CH_ATTENTION).setContentTitle(title).setContentText(a.text).setAutoCancel(true)
            .setContentIntent(openApp(route, 40 + a.kind.ordinal)).build()
        notifySafely(ID_ATTENTION_BASE + a.kind.ordinal, n)
    }

    fun clearAttention(kind: AttentionKind) { nm.cancel(ID_ATTENTION_BASE + kind.ordinal) }

    override fun reviewWaiting(rule: RuleEntity, review: ReviewEntity) {
        val n = base(CH_REVIEWS).setContentTitle("Check before deleting")
            .setContentText("${rule.name}: ${review.fileCount} files (${Fmt.size(review.totalBytes)}) are ready to delete from your phone.")
            .setAutoCancel(true).setContentIntent(openApp("review:${rule.id}", 60 + rule.id.toInt())).build()
        notifySafely(ID_REVIEW_BASE + rule.id.toInt(), n)
    }

    private fun notifySafely(id: Int, n: android.app.Notification) {
        try {
            if (Build.VERSION.SDK_INT >= 33 && !NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            nm.notify(id, n)
        } catch (_: SecurityException) {
            // notification permission refused: uploads carry on, Home shows the warning
        }
    }
}
