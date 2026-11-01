package com.aakashchamola.telebackup

import android.content.Intent
import com.aakashchamola.telebackup.bridge.CoreEventsBridge
import com.aakashchamola.telebackup.bridge.CoreHostApi
import com.aakashchamola.telebackup.bridge.CoreHostApiImpl
import com.aakashchamola.telebackup.core.di.ServiceLocator
import com.aakashchamola.telebackup.core.notify.Notifier
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var events: CoreEventsBridge? = null
    private var pendingRoute: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val locator = ServiceLocator.get(this)
        CoreHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, CoreHostApiImpl(applicationContext))
        events = CoreEventsBridge(flutterEngine.dartExecutor.binaryMessenger, locator).also { it.start() }
        pendingRoute = intent?.getStringExtra(Notifier.EXTRA_ROUTE)
        pendingRoute?.let { events?.openRoute(it); pendingRoute = null }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(Notifier.EXTRA_ROUTE)?.let { events?.openRoute(it) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        events?.stop(); events = null
        CoreHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
