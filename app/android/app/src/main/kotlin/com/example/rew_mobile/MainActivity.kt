package com.example.rew_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import com.rewmobile.audio.RewAudioPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Measurement audio (UMIK-1 capture + sweep playback) lives in RewAudioPlugin;
        // all DSP stays in rewcore via FFI.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rew_mobile/audio")
            .setMethodCallHandler(RewAudioPlugin(applicationContext))

        requestMicPermission()
    }

    private fun requestMicPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1001)
        }
    }
}
