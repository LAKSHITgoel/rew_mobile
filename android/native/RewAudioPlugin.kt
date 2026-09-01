// Android reference implementation of the `rew_mobile/audio` MethodChannel.
//
// STATUS: reference implementation — needs validation on real hardware. Drop this
// into the Flutter plugin's android/src/main/kotlin tree and register it from the
// plugin's `onAttachedToEngine`.
//
// Strategy (simplest-that-can-work first):
//   * Input: capture the UMIK-1 with AudioRecord, pinned to the USB input device via
//     setPreferredDevice(). Many UAC1 mics enumerate as TYPE_USB_DEVICE and record
//     fine this way — try this before reaching for a libusb isochronous driver.
//   * Output: play the sweep with AudioTrack as MEDIA usage, so it routes out over
//     wireless Android Auto / A2DP to the OEM head unit while the mic records.
//
// Fallback (documented in android/native/README.md): if a given device won't expose
// the UMIK-1 to AudioRecord, ship a libusb-based UAC isochronous IN driver in the NDK.
package com.rewmobile.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class RewAudioPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "micStatus" -> result.success(micStatus())
            "playSweepAndCapture" -> {
                val bytes = call.argument<ByteArray>("sweep")
                val fs = (call.argument<Double>("fs") ?: 48000.0)
                if (bytes == null) {
                    result.error("ARG", "missing sweep", null); return
                }
                // Run off the platform thread.
                thread {
                    try {
                        val sweep = decodeF64(bytes)
                        val rec = playAndCapture(sweep, fs.toInt())
                        result.success(rec)
                    } catch (e: Exception) {
                        result.error("CAPTURE", e.message, null)
                    }
                }
            }
            "dispose" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun audioManager() =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun usbInput(): AudioDeviceInfo? =
        audioManager().getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }

    private fun micStatus(): Map<String, Any?> {
        val dev = usbInput()
        return mapOf(
            "connected" to (dev != null),
            "name" to dev?.productName?.toString(),
        )
    }

    /** Play [sweep] (mono, [-1,1]) as media while capturing the USB mic. Returns the
     *  recorded mono samples as doubles (a DoubleArray -> Float64List on the Dart side). */
    private fun playAndCapture(sweep: DoubleArray, fs: Int): DoubleArray {
        val minRec = AudioRecord.getMinBufferSize(
            fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT
        ).coerceAtLeast(4096)

        val record = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.UNPROCESSED)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(fs)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build()
            )
            .setBufferSizeInBytes(minRec * 4)
            .build()

        usbInput()?.let { record.preferredDevice = it }

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(fs)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        // Capture for the sweep length plus ~0.3 s of latency/decay tail.
        val captureLen = sweep.size + (fs * 0.3).toInt()
        val captured = FloatArray(captureLen)
        val playBuf = FloatArray(sweep.size) { sweep[it].toFloat() }

        record.startRecording()
        track.play()

        val reader = thread {
            var off = 0
            while (off < captureLen) {
                val n = record.read(
                    captured, off, minOf(minRec, captureLen - off),
                    AudioRecord.READ_BLOCKING
                )
                if (n <= 0) break
                off += n
            }
        }

        var wrote = 0
        while (wrote < playBuf.size) {
            val n = track.write(
                playBuf, wrote, playBuf.size - wrote, AudioTrack.WRITE_BLOCKING
            )
            if (n <= 0) break
            wrote += n
        }

        reader.join()
        track.stop(); track.release()
        record.stop(); record.release()

        return DoubleArray(captured.size) { captured[it].toDouble() }
    }

    private fun decodeF64(bytes: ByteArray): DoubleArray {
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val out = DoubleArray(bytes.size / 8)
        for (i in out.indices) out[i] = bb.double
        return out
    }
}
