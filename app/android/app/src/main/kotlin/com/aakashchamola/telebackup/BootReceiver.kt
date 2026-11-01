package com.aakashchamola.telebackup

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.aakashchamola.telebackup.core.log.Tlog

/** After a restart (or an app update) Android starts our process for this broadcast; [TeleBackupApp.onCreate] does the real work. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Tlog.i("process started by ${intent.action}")
    }
}
