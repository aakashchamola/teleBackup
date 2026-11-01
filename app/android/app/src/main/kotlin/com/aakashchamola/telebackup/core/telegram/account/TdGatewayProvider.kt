package com.aakashchamola.telebackup.core.telegram.account

import android.content.Context

/** Makes the TDLib gateway. Null while the TDLib library is not part of the build; see docs/STATUS.md. */
object TdGatewayProvider {
    fun create(@Suppress("UNUSED_PARAMETER") context: Context): TdGateway? = null
}
