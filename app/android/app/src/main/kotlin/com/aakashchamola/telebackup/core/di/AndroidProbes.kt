package com.aakashchamola.telebackup.core.di

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import androidx.core.app.NotificationManagerCompat
import com.aakashchamola.telebackup.core.status.NetworkProbe
import com.aakashchamola.telebackup.core.status.PermissionProbe
import com.aakashchamola.telebackup.core.status.PermissionState

class AndroidPermissionProbe(private val context: Context) : PermissionProbe {
    override fun state(): PermissionState {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val media = Build.VERSION.SDK_INT < 33 ||
            (context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED &&
                context.checkSelfPermission(Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED)
        return PermissionState(
            notifications = NotificationManagerCompat.from(context).areNotificationsEnabled(),
            allFiles = Environment.isExternalStorageManager(),
            batteryExempt = pm.isIgnoringBatteryOptimizations(context.packageName),
            mediaRead = media,
        )
    }
}

class AndroidNetworkProbe(private val context: Context) : NetworkProbe {
    private val cm get() = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private fun caps(): NetworkCapabilities? = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }

    override fun onUnmetered(): Boolean = caps()?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true
    override fun online(): Boolean = caps()?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
}
