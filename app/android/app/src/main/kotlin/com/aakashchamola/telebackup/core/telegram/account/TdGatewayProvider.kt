package com.aakashchamola.telebackup.core.telegram.account

import android.content.Context

/** Makes the TDLib gateway. Null only if the native library cannot be loaded on this phone. */
object TdGatewayProvider {
    fun create(context: Context): TdGateway? = try {
        val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
        TdlibGateway(version)
    } catch (e: Throwable) {   // UnsatisfiedLinkError on an unsupported CPU: the account stays off, the bot still works
        com.aakashchamola.telebackup.core.log.Tlog.w("TDLib not available: ${e.javaClass.simpleName}")
        null
    }
}
