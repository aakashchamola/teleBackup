package com.aakashchamola.telebackup.core.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.aakashchamola.telebackup.core.control.ControlActions
import com.aakashchamola.telebackup.core.di.ServiceLocator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** The Pause / Delay / Resume buttons on the notification. Not exported: only our own PendingIntents reach it. */
class ControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val sl = ServiceLocator.get(context)
                when (intent.action) {
                    Notifier.ACTION_PAUSE -> ControlActions.pause(sl)
                    Notifier.ACTION_DELAY -> ControlActions.delay(sl, intent.getIntExtra(Notifier.EXTRA_MINUTES, 120))
                    Notifier.ACTION_RESUME -> ControlActions.resume(sl)
                }
                sl.statusHub.refresh()
            } finally {
                pending.finish()
            }
        }
    }
}
