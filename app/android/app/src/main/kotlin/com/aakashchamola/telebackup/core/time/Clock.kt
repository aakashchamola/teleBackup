package com.aakashchamola.telebackup.core.time

/** Time is always read through this, so tests and the debug time warp can control it. */
interface Clock {
    fun now(): Long
}

object SystemClockImpl : Clock {
    override fun now(): Long = System.currentTimeMillis()
}

object Time {
    const val MINUTE = 60_000L
    const val HOUR = 60 * MINUTE
    const val DAY = 24 * HOUR
}
