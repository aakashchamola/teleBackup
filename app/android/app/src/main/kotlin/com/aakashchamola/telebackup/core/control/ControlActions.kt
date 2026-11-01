package com.aakashchamola.telebackup.core.control

import com.aakashchamola.telebackup.core.di.ServiceLocator

/** Pause, Delay and Resume as the notification buttons and the Home screen both do them. */
object ControlActions {
    fun pause(sl: ServiceLocator) {
        sl.control.pause()
        if (sl.runTracker.running) { sl.runTracker.pausing = true; sl.notifier.updateProgress(force = true) }
        else showHeld(sl)
        sl.statusHub.refresh()
    }

    fun delay(sl: ServiceLocator, minutes: Int) {
        sl.control.delay(minutes)
        if (sl.runTracker.running) sl.runTracker.pausing = true else showHeld(sl)
        sl.statusHub.refresh()
    }

    fun resume(sl: ServiceLocator) {
        sl.control.resume()
        sl.notifier.cancelControl()
        sl.statusHub.refresh()
    }

    private fun showHeld(sl: ServiceLocator) =
        sl.notifier.showControlState(sl.fileStore.queueCount(sl.clock.now(), true, true).count)
}
