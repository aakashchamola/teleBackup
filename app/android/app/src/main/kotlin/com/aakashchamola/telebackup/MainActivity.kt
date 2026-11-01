package com.aakashchamola.telebackup

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "telebackup/hello")
            .setMethodCallHandler { call, result ->
                if (call.method == "ping") {
                    result.success("pong (Android ${Build.VERSION.RELEASE}, ${Build.MODEL})")
                } else {
                    result.notImplemented()
                }
            }
    }
}
