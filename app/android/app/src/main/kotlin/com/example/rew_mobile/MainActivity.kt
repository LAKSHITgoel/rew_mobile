package com.example.rew_mobile

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import com.rewmobile.audio.RewAudioPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    /** The pending picker reply. A MethodChannel.Result must be answered exactly
     *  once, so this is cleared before every completion path. */
    private var pendingPick: MethodChannel.Result? = null

    companion object {
        private const val REQ_PICK_TEXT = 2001
        private const val CHANNEL_AUDIO = "rew_mobile/audio"
        private const val CHANNEL_FILES = "rew_mobile/files"
        private const val CHANNEL_LEVELS = "rew_mobile/audio_levels"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Measurement audio (UMIK-1 capture + sweep playback); all DSP is in rewcore.
        val audio = RewAudioPlugin(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_AUDIO)
            .setMethodCallHandler(audio)
        // Live mic level, so the user can confirm the mic is actually hearing
        // something before running a sweep.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_LEVELS)
            .setStreamHandler(audio)

        // File picking lives here rather than in a plugin because it needs an
        // Activity to receive the document-picker result.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_FILES)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickTextFile" -> pickTextFile(result)
                    // Where saved tunes live. Returned from native so the app
                    // needs no path_provider dependency.
                    "appDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }

        requestMicPermission()
    }

    /** Opens the system document picker; replies with the file's text, or null if
     *  the user cancelled. */
    private fun pickTextFile(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "a file picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // A .txt from a vendor download often reports as octet-stream, so accept
            // anything and let parsing decide.
            type = "*/*"
        }
        try {
            startActivityForResult(intent, REQ_PICK_TEXT)
        } catch (e: Exception) {
            pendingPick = null
            result.error("PICK", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_TEXT) return
        val result = pendingPick ?: return
        pendingPick = null

        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)  // cancelled
            return
        }
        try {
            val text = contentResolver.openInputStream(uri)
                ?.bufferedReader()?.use { it.readText() }
            result.success(text)
        } catch (e: Exception) {
            result.error("READ", e.message, null)
        }
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
