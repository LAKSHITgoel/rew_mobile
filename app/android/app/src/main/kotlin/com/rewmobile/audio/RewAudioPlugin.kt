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
import android.util.Log
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

private const val TAG = "RewAudio"

class RewAudioPlugin(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())

    // Live input-level monitoring (so the user can confirm the mic actually hears
    // something before wasting a sweep on a dead connection).
    private var levelSink: EventChannel.EventSink? = null
    @Volatile private var levelRunning = false
    private var levelThread: Thread? = null
    // Held so stop() can unblock a thread parked in AudioRecord.read().
    @Volatile private var levelRecord: AudioRecord? = null

    // Looped tone/noise playback for manual time alignment.
    @Volatile private var toneRunning = false
    private var toneThread: Thread? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        levelSink = events
    }

    override fun onCancel(arguments: Any?) {
        levelSink = null
    }

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
            "startInputLevel" -> { startInputLevel(); result.success(null) }
            "stopInputLevel" -> { stopInputLevel(); result.success(null) }
            "startTone" -> {
                val bytes = call.argument<ByteArray>("samples")
                val fs = (call.argument<Double>("fs") ?: 48000.0)
                if (bytes == null) { result.error("ARG", "missing samples", null) }
                else { startTone(decodeF64(bytes), fs.toInt()); result.success(null) }
            }
            "stopTone" -> { stopTone(); result.success(null) }
            "dispose" -> { stopInputLevel(); stopTone(); result.success(null) }
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
                if (r.state == AudioRecord.STATE_INITIALIZED) {
                    // Asking for a rate is not being given it. If the device
                    // opened at a different one, the recording is on another
                    // time base than the sweep and every frequency in the
                    // result is wrong by that ratio — a silent, plausible
                    // error. iOS already refuses this; Android must too.
                    if (r.sampleRate != fs) {
                        val got = r.sampleRate
                        r.release()
                        throw IllegalStateException(
                            "microphone opened at $got Hz, not the $fs Hz the " +
                                "sweep was generated for"
                        )
                    }
                    return r
                }
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

        var got = 0
        try {
            Log.i(TAG, "capture start: fs=$fs frames=$captureLen")
            record.startRecording()
            if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw IllegalStateException(
                    "microphone did not start recording (is it still plugged in?)"
                )
            }
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
                got = off
            }

            var wrote = 0
            while (wrote < playBuf.size) {
                val n = track.write(
                    playBuf, wrote, playBuf.size - wrote, AudioTrack.WRITE_BLOCKING
                )
                if (n <= 0) break
                wrote += n
            }

            // read() blocks, and returns nothing at all if the mic disappears
            // mid-capture. Never wait on it unbounded: a reader thread parked
            // here used to hang the method call forever, which left the app's
            // Measure button permanently disabled. Stopping the record unblocks
            // a parked read().
            val budgetMs = (captureLen * 1000L) / fs + 5000L
            reader.join(budgetMs)
            if (reader.isAlive) {
                runCatching { record.stop() }
                reader.join(1000)
            }
            Log.i(TAG, "capture done: $got/$captureLen frames")
            if (got < captureLen / 2) {
                throw IllegalStateException(
                    "microphone returned no audio (captured $got of $captureLen frames)"
                )
            }
        } finally {
            runCatching { track.stop() }; track.release()
            runCatching { record.stop() }; record.release()
        }

        return DoubleArray(captured.size) { captured[it].toDouble() }
    }

    /** Streams input level (dBFS RMS) to Dart ~20x/second. */
    private fun startInputLevel() {
        if (levelRunning) return
        levelRunning = true
        levelThread = thread {
            val fs = 48000
            val minBuf = AudioRecord.getMinBufferSize(
                fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT
            ).coerceAtLeast(2048)
            var record: AudioRecord? = null
            try {
                record = buildRecord(fs, minBuf * 2)
                levelRecord = record
                usbInput()?.let { record.preferredDevice = it }
                record.startRecording()
                val block = FloatArray(fs / 20)  // ~50 ms
                while (levelRunning) {
                    val n = record.read(block, 0, block.size, AudioRecord.READ_BLOCKING)
                    if (n <= 0) continue
                    var sum = 0.0
                    var peak = 0.0
                    for (i in 0 until n) {
                        val v = block[i].toDouble()
                        sum += v * v
                        if (kotlin.math.abs(v) > peak) peak = kotlin.math.abs(v)
                    }
                    val rms = kotlin.math.sqrt(sum / n)
                    val rmsDb = 20.0 * kotlin.math.log10(rms + 1e-12)
                    val peakDb = 20.0 * kotlin.math.log10(peak + 1e-12)
                    main.post {
                        levelSink?.success(mapOf("rmsDb" to rmsDb, "peakDb" to peakDb))
                    }
                }
            } catch (e: Exception) {
                main.post { levelSink?.error("LEVEL", e.message, null) }
            } finally {
                runCatching { record?.stop() }
                runCatching { record?.release() }
                levelRecord = null
            }
        }
    }

    private fun stopInputLevel() {
        levelRunning = false
        // read() is blocking, so the thread will not notice levelRunning until it
        // returns. Stopping the record first unblocks it; without this the join
        // times out and the next start races a still-live AudioRecord.
        runCatching { levelRecord?.stop() }
        runCatching { levelThread?.join(1000) }
        levelThread = null
        levelRecord = null
    }

    /** Loops [samples] out as media until stopTone(); used for centring by ear. */
    private fun startTone(samples: DoubleArray, fs: Int) {
        stopTone()
        toneRunning = true
        toneThread = thread {
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
            val buf = FloatArray(samples.size) { samples[it].toFloat() }
            try {
                track.play()
                while (toneRunning) {
                    var off = 0
                    while (toneRunning && off < buf.size) {
                        val n = track.write(buf, off, buf.size - off, AudioTrack.WRITE_BLOCKING)
                        if (n <= 0) break
                        off += n
                    }
                }
            } catch (e: Exception) {
                main.post { levelSink?.error("TONE", e.message, null) }
            } finally {
                runCatching { track.stop() }
                track.release()
            }
        }
    }

    private fun stopTone() {
        toneRunning = false
        runCatching { toneThread?.join(500) }
        toneThread = null
    }

    private fun decodeF64(bytes: ByteArray): DoubleArray {
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val out = DoubleArray(bytes.size / 8)
        for (i in out.indices) out[i] = bb.double
        return out
    }
}
