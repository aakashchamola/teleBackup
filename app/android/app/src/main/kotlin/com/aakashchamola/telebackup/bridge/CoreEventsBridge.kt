package com.aakashchamola.telebackup.bridge

import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.log.Tlog
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest

/** Forwards status to the screens while the UI is alive, at most twice a second. When the UI is closed the notification is the UI. */
class CoreEventsBridge(messenger: BinaryMessenger, private val locator: ServiceLocator) {
    private val api = CoreEventsApi(messenger)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null

    fun start() {
        job = scope.launch {
            locator.statusHub.state.collectLatest { snapshot ->
                if (snapshot != null) {
                    try { api.onStatus(snapshot.toBridge()) } catch (e: Exception) { Tlog.w("status not delivered", e) }
                    delay(500)
                }
            }
        }
    }

    fun openRoute(route: String) {
        scope.launch { try { api.onOpenRoute(route) } catch (e: Exception) { Tlog.w("route not delivered", e) } }
    }

    fun rulesChanged() { scope.launch { try { api.onRulesChanged() } catch (_: Exception) {} } }

    fun stop() { job?.cancel(); scope.cancel() }
}
