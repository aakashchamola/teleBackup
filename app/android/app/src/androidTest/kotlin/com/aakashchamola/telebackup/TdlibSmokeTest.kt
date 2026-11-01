package com.aakashchamola.telebackup

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.aakashchamola.telebackup.core.telegram.account.TdAuth
import com.aakashchamola.telebackup.core.telegram.account.TdParams
import com.aakashchamola.telebackup.core.telegram.account.TdStep
import com.aakashchamola.telebackup.core.telegram.account.TdlibGateway
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Proves the TDLib native library loads on this phone and its login state moves, with a deliberately wrong api_id,
 * so no code is ever sent and no account is touched. Uses a throwaway database folder.
 */
@RunWith(AndroidJUnit4::class)
class TdlibSmokeTest {
    @Test
    fun startsAndAsksForAPhoneNumber() = runBlocking<Unit> {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(ctx.cacheDir, "tdsmoke-${System.nanoTime()}")
        val gw = TdlibGateway("test")
        try {
            gw.open(TdParams(1, "0123456789abcdef0123456789abcdef", File(base, "db"), File(base, "files"), "00".repeat(32)))
            val st = withTimeout(30_000) { gw.auth.first { it is TdAuth.WaitPhone || it is TdAuth.WaitOther } }
            assertThat(st).isEqualTo(TdAuth.WaitPhone)
            val r = withTimeout(30_000) { gw.submitPhone("+10000000000") }
            // Telegram refuses the made-up api_id before any code is sent
            assertThat(r).isInstanceOf(TdStep.Rejected::class.java)
        } finally {
            gw.close()
            base.deleteRecursively()
        }
    }
}
