// Android implementation of the `rew_mobile/audio` MethodChannel.
//
// Input: captures the UMIK-1 with AudioRecord pinned to the USB input device via
// setPreferredDevice(). Many UAC1 mics enumerate as TYPE_USB_DEVICE and record fine
// this way; if a device won't expose the mic here, the fallback is a libusb-based UAC
// isochronous driver in the NDK (see android/native/README.md).
//
// Output: plays the sweep with AudioTrack as MEDIA usage, so it routes out over
// wireless Android Auto / A2DP to the OEM head unit while the mic records.
//
// STATUS: needs on-device validation (Spike #0).
package com.rewmobile.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class RewAudioPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "micStatus" -> result.success(micStatus())
            "playSweepAndCapture" -> {
                val bytes = call.argument<ByteArray>("sweep")
                val fs = (call.argument<Double>("fs") ?: 48000.0)
                if (bytes == null) {
                    result.error("ARG", "missing sweep", null); return
                }
                // Capture must not block the platform thread; MethodChannel.Result,
                // however, may only be touched on the main thread — hence the post.
                thread {
                    try {
                        val sweep = decodeF64(bytes)
                        val rec = playAndCapture(sweep, fs.toInt())
                        main.post { result.success(rec) }
                    } catch (e: Exception) {
                        main.post { result.error("CAPTURE", e.message, null) }
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

    /** Build an AudioRecord, preferring an unprocessed source (no AGC/noise
     *  suppression, which would ruin a measurement) and falling back if the device
     *  or ROM rejects it. */
    private fun buildRecord(fs: Int, bufBytes: Int): AudioRecord {
        val sources = intArrayOf(
            MediaRecorder.AudioSource.UNPROCESSED,
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
        )
        var last: Exception? = null
        for (src in sources) {
            try {
                val r = AudioRecord.Builder()
                    .setAudioSource(src)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                            .setSampleRate(fs)
                            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(bufBytes)
                    .build()
                if (r.state == AudioRecord.STATE_INITIALIZED) return r
                r.release()
            } catch (e: Exception) {
                last = e
            }
        }
        throw IllegalStateException("could not open AudioRecord", last)
    }

    /** Play [sweep] (mono, [-1,1]) as media while capturing the USB mic. Returns the
     *  recorded mono samples as doubles (DoubleArray -> Float64List in Dart). */
    private fun playAndCapture(sweep: DoubleArray, fs: Int): DoubleArray {
        val minRec = AudioRecord.getMinBufferSize(
            fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT
        ).coerceAtLeast(4096)

        val record = buildRecord(fs, minRec * 4)
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

        // Capture the sweep plus ~0.5 s for wireless latency and the decay tail.
        val captureLen = sweep.size + (fs * 0.5).toInt()
        val captured = FloatArray(captureLen)
        val playBuf = FloatArray(sweep.size) { sweep[it].toFloat() }

        try {
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
        } finally {
            runCatching { track.stop() }; track.release()
            runCatching { record.stop() }; record.release()
        }

        return DoubleArray(captured.size) { captured[it].toDouble() }
    }

    private fun decodeF64(bytes: ByteArray): DoubleArray {
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val out = DoubleArray(bytes.size / 8)
        for (i in out.indices) out[i] = bb.double
        return out
    }
}
