package com.aakashchamola.telebackup.core.upload

import com.aakashchamola.telebackup.core.model.Route
import com.aakashchamola.telebackup.core.time.Clock
import kotlinx.coroutines.delay

/**
 * Keeps us under Telegram's limits. Bot: a token bucket (default 15 a minute, burst 3).
 * Account: a minimum gap between uploads. A flood-wait blocks every route.
 */
class Pacer(
    private val clock: Clock,
    private val botPerMinute: Int = 15,
    private val burst: Int = 3,
    private val accountMinGapMs: Long = 10_000,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private var tokens = burst.toDouble()
    private var lastRefill = clock.now()
    private var lastAccountStart = Long.MIN_VALUE / 2
    private var blockedUntil = 0L
    private val routeBlockedUntil = HashMap<Route, Long>()

    /** Telegram said wait: nothing is sent on any route before [untilMillis]. */
    @Synchronized
    fun blockAll(untilMillis: Long) {
        if (untilMillis > blockedUntil) blockedUntil = untilMillis
    }

    /** Telegram said wait on one route only (a long account flood-wait must not hold up bot uploads). */
    @Synchronized
    fun blockRoute(route: Route, untilMillis: Long) {
        if (untilMillis > (routeBlockedUntil[route] ?: 0L)) routeBlockedUntil[route] = untilMillis
    }

    /** Takes a slot and returns how long to wait first, in milliseconds (0 = go now). */
    @Synchronized
    fun reserve(route: Route): Long {
        val now = clock.now()
        refill(now)
        var wait = maxOf(0L, blockedUntil - now, (routeBlockedUntil[route] ?: 0L) - now)
        when (route) {
            Route.BOT -> {
                val perMs = botPerMinute / 60_000.0
                if (tokens < 1.0) wait = maxOf(wait, kotlin.math.ceil((1.0 - tokens) / perMs).toLong())
                tokens -= 1.0   // may go below zero: the debt is what makes the next caller wait
            }
            Route.ACCOUNT -> {
                val next = lastAccountStart + accountMinGapMs
                wait = maxOf(wait, next - now)
                lastAccountStart = now + wait
            }
        }
        return wait
    }

    suspend fun awaitSlot(route: Route) {
        val wait = reserve(route)
        if (wait > 0) sleep(wait)
    }

    private fun refill(now: Long) {
        val perMs = botPerMinute / 60_000.0
        tokens = minOf(burst.toDouble(), tokens + (now - lastRefill) * perMs)
        lastRefill = now
    }
}
