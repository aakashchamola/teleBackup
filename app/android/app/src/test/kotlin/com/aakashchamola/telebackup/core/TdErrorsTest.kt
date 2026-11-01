package com.aakashchamola.telebackup.core

import com.aakashchamola.telebackup.core.telegram.TgError
import com.aakashchamola.telebackup.core.telegram.account.TdErrors
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class TdErrorsTest {
    @Test fun sendErrorsMapToKinds() {
        assertThat(TdErrors.forSend(429, "Too Many Requests: retry after 17")).isEqualTo(TgError.FloodWait(17))
        assertThat(TdErrors.forSend(420, "FLOOD_WAIT_45")).isEqualTo(TgError.FloodWait(45))
        assertThat(TdErrors.forSend(429, "Too Many Requests")).isEqualTo(TgError.FloodWait(30))
        assertThat(TdErrors.forSend(401, "AUTH_KEY_UNREGISTERED")).isEqualTo(TgError.AccountLoggedOut)
        assertThat(TdErrors.forSend(401, "SESSION_REVOKED")).isEqualTo(TgError.AccountLoggedOut)
        assertThat(TdErrors.forSend(400, "TOPIC_DELETED")).isEqualTo(TgError.TopicMissing)
        assertThat(TdErrors.forSend(400, "MESSAGE_THREAD_INVALID")).isEqualTo(TgError.TopicMissing)
        assertThat(TdErrors.forSend(403, "CHAT_WRITE_FORBIDDEN")).isInstanceOf(TgError.Forbidden::class.java)
        assertThat(TdErrors.forSend(400, "FILE_PARTS_INVALID")).isEqualTo(TgError.TooLarge)
        assertThat(TdErrors.forSend(502, "Bad Gateway")).isEqualTo(TgError.Server(502))
        assertThat(TdErrors.forSend(400, "WHATEVER")).isInstanceOf(TgError.BadRequest::class.java)
    }

    @Test fun loginErrorsAreInPlainWords() {
        assertThat(TdErrors.forLogin(400, "PHONE_NUMBER_INVALID")).isEqualTo("That phone number is not valid.")
        assertThat(TdErrors.forLogin(400, "PHONE_CODE_INVALID")).isEqualTo("That code is not right.")
        assertThat(TdErrors.forLogin(400, "PHONE_CODE_EXPIRED")).contains("expired")
        assertThat(TdErrors.forLogin(400, "PASSWORD_HASH_INVALID")).isEqualTo("That password is not right.")
        assertThat(TdErrors.forLogin(429, "Too Many Requests: retry after 120")).contains("120 seconds")
        assertThat(TdErrors.forLogin(400, "API_ID_INVALID")).contains("api_id")
        assertThat(TdErrors.forLogin(500, "weird internal text")).doesNotContain("weird")
    }

    @Test fun phoneIsMaskedToTheLastThreeDigits() {
        assertThat(TdErrors.maskPhone("919876543210")).isEqualTo("+•• ••••• ••210")
        assertThat(TdErrors.maskPhone("+91 98765 43210")).endsWith("210")
        assertThat(TdErrors.maskPhone("12")).isNull()
        assertThat(TdErrors.maskPhone(null)).isNull()
        assertThat(TdErrors.maskPhone("919876543210")).doesNotContain("9876")
    }
}
