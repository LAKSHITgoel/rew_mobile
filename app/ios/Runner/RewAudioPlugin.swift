// iOS half of the `rew_mobile/audio` channel: capture the UMIK-1 over USB while
// the measurement sweep plays out over wireless CarPlay / Bluetooth, so the
// measurement passes through the real OEM + DSP chain. Mirrors the Android
// RewAudioPlugin.kt — same method names, same argument shapes, same replies —
// because the Dart side (native_audio_backend.dart) is shared.
//
// This layer does I/O only. All measurement DSP lives in core/ (C++).
//
// Two hard rules, both learned the hard way on Android:
//   * Never block the platform thread. Capture runs on `work` and every reply is
//     posted back on the main thread; a blocked main thread is an ANR on Android
//     and a watchdog kill here.
//   * Never wait unbounded, and never return audio we are not sure about. A
//     capture that silently returns nothing looks exactly like a dead button.
import AVFoundation
import Flutter
import UIKit

public final class RewAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let engine = AVAudioEngine()
    private let sweepPlayer = AVAudioPlayerNode()
    private let tonePlayer = AVAudioPlayerNode()
    private let work = DispatchQueue(label: "com.rewmobile.audio")

    private let lock = NSLock()
    private var captured: [Float] = []
    private var captureWanted = 0
    private var captureDone: DispatchSemaphore?

    private var levelSink: FlutterEventSink?
    private var levelTapped = false
    private var lastLevelSent = Date.distantPast
    private var tonePlaying = false
    private var sendBlocks = false

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RewAudioPlugin()
        let channel = FlutterMethodChannel(name: "rew_mobile/audio",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "rew_mobile/audio_levels",
                            binaryMessenger: registrar.messenger())
            .setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "micStatus":
            work.async {
                let status = self.micStatus()
                DispatchQueue.main.async { result(status) }
            }

        case "playSweepAndCapture":
            guard let data = args["sweep"] as? FlutterStandardTypedData,
                  let fs = args["fs"] as? Double else {
                result(FlutterError(code: "bad_args",
                                    message: "sweep and fs are required", details: nil))
                return
            }
            let sweep = RewAudioPlugin.decodeF64(data.data)
            work.async {
                do {
                    let rec = try self.playAndCapture(sweep: sweep, fs: fs)
                    let out = rec.withUnsafeBufferPointer { Data(buffer: $0) }
                    DispatchQueue.main.async {
                        result(FlutterStandardTypedData(float64: out))
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "capture_failed",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            }

        case "startInputLevel":
            // When true the level stream also carries the raw samples, which is
            // what the real-time analyser needs. Same tap rather than a second
            // one: only one tap may be installed on the input bus.
            sendBlocks = (args["withSamples"] as? Bool) ?? false
            work.async {
                do {
                    try self.startInputLevel()
                    DispatchQueue.main.async { result(nil) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "level_failed",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            }

        case "stopInputLevel":
            work.async {
                self.stopInputLevel()
                DispatchQueue.main.async { result(nil) }
            }

        case "startTone":
            guard let data = args["samples"] as? FlutterStandardTypedData,
                  let fs = args["fs"] as? Double else {
                result(FlutterError(code: "bad_args",
                                    message: "samples and fs are required", details: nil))
                return
            }
            let samples = RewAudioPlugin.decodeF64(data.data)
            work.async {
                do {
                    try self.startTone(samples: samples, fs: fs)
                    DispatchQueue.main.async { result(nil) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "tone_failed",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            }

        case "stopTone":
            work.async {
                self.stopTone()
                DispatchQueue.main.async { result(nil) }
            }

        case "dispose":
            work.async {
                self.stopTone()
                self.stopInputLevel()
                self.teardown()
                DispatchQueue.main.async { result(nil) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Mic

    /// The UMIK-1 arrives as a USB audio input — straight into the USB-C port on
    /// an iPhone 15 or later, or through a camera adapter on a Lightning phone.
    /// Reported by name so the app can say which mic it found.
    private func micStatus() -> [String: Any] {
        // Without record permission the mic is simply missing from
        // availableInputs, so a plugged-in UMIK-1 would be reported as absent.
        // Ask first, and say so plainly if the answer is no.
        guard ensureRecordPermission() else {
            return ["connected": false, "name": "Microphone access denied"]
        }
        let session = AVAudioSession.sharedInstance()
        // availableInputs is only populated once the session knows it may record.
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.allowBluetoothA2DP])
        let usb = session.availableInputs?.first { $0.portType == .usbAudio }
        var info: [String: Any] = ["connected": usb != nil]
        if let name = usb?.portName { info["name"] = name }
        return info
    }

    /// Blocks the calling (background) queue until the user has answered the
    /// microphone prompt. iOS 17 moved this from AVAudioSession to
    /// AVAudioApplication; the project still deploys to iOS 15, so both paths
    /// stay.
    private func ensureRecordPermission() -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            default: break
            }
            var granted = false
            let sem = DispatchSemaphore(value: 0)
            AVAudioApplication.requestRecordPermission { ok in
                granted = ok
                sem.signal()
            }
            sem.wait()
            return granted
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted: return true
            case .denied: return false
            default: break
            }
            var granted = false
            let sem = DispatchSemaphore(value: 0)
            session.requestRecordPermission { ok in
                granted = ok
                sem.signal()
            }
            sem.wait()
            return granted
        }
    }

    // MARK: - Capture

    private enum CaptureError: LocalizedError {
        case sampleRate(want: Double, got: Double)
        case noAudio(got: Int, want: Int)
        case timedOut
        case noPermission

        var errorDescription: String? {
            switch self {
            case let .sampleRate(want, got):
                return "The device would not run at \(Int(want)) Hz (it is at "
                    + "\(Int(got)) Hz), so the recording would not line up with "
                    + "the sweep."
            case let .noAudio(got, want):
                return "The microphone returned no audio (\(got) of \(want) "
                    + "frames). Check it is still plugged in, then try again."
            case .timedOut:
                return "The microphone did not return any audio in time. Check it "
                    + "is still plugged in, then try again."
            case .noPermission:
                return "This app is not allowed to use the microphone. Turn it on "
                    + "in Settings > Privacy & Security > Microphone."
            }
        }
    }

    /// Plays `sweep` out of the current route and records the mic at the same
    /// time. Returns the recording, which is longer than the sweep: it carries
    /// the wireless latency as leading silence plus the room's decay tail, and
    /// the deconvolution in core/ finds the alignment itself.
    private func playAndCapture(sweep: [Double], fs: Double) throws -> [Double] {
        guard ensureRecordPermission() else { throw CaptureError.noPermission }
        stopInputLevel()   // only one tap may be installed on the input bus
        stopTone()

        let session = AVAudioSession.sharedInstance()
        // .measurement turns off the system's own EQ/AGC — the point here is to
        // hear the car, not Apple's idea of a nice voice. A2DP is what carries
        // the sweep to the head unit.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothA2DP])
        try session.setPreferredSampleRate(fs)
        if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? session.setPreferredInput(usb)
        }
        try session.setActive(true)

        // The sweep was generated for `fs`. If the hardware insists on another
        // rate the recording is on a different time base and every frequency in
        // the result is wrong, so refuse rather than return a plausible lie.
        let sr = session.sampleRate
        guard abs(sr - fs) < 1.0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.sampleRate(want: fs, got: sr)
        }

        let input = engine.inputNode
        // The tap format must be the input's own format or AVAudioEngine traps.
        let inFormat = input.inputFormat(forBus: 0)

        let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sr, channels: 1,
                                       interleaved: false)!
        let frames = AVAudioFrameCount(sweep.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat,
                                         frameCapacity: frames) else {
            throw CaptureError.noAudio(got: 0, want: sweep.count)
        }
        buf.frameLength = frames
        let dst = buf.floatChannelData![0]
        for i in 0..<sweep.count { dst[i] = Float(sweep[i]) }

        // Capture the sweep plus ~0.5 s for wireless latency and the decay tail,
        // matching the Android side.
        let wanted = sweep.count + Int(sr * 0.5)
        lock.lock()
        captured = []
        captured.reserveCapacity(wanted)
        captureWanted = wanted
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        captureDone = done

        if sweepPlayer.engine == nil { engine.attach(sweepPlayer) }
        engine.connect(sweepPlayer, to: engine.mainMixerNode, format: playFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] b, _ in
            guard let self = self, let src = b.floatChannelData?[0] else { return }
            let n = Int(b.frameLength)
            self.lock.lock()
            if self.captured.count < self.captureWanted {
                for i in 0..<n { self.captured.append(src[i]) }
                if self.captured.count >= self.captureWanted {
                    self.captureDone?.signal()
                }
            }
            self.lock.unlock()
        }

        defer {
            input.removeTap(onBus: 0)
            sweepPlayer.stop()
            engine.stop()
            captureDone = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        engine.prepare()
        try engine.start()
        sweepPlayer.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        sweepPlayer.play()

        // Bounded, always. Waiting on the mic forever is what left the Android UI
        // stuck "busy" with a Measure button that ignored taps.
        let budget = Double(wanted) / sr + 5.0
        let waited = done.wait(timeout: .now() + budget)

        lock.lock()
        let got = captured
        lock.unlock()

        if waited == .timedOut && got.count < wanted / 2 {
            throw got.isEmpty ? CaptureError.timedOut
                              : CaptureError.noAudio(got: got.count, want: wanted)
        }
        guard got.count >= wanted / 2 else {
            throw CaptureError.noAudio(got: got.count, want: wanted)
        }
        return got.map { Double($0) }
    }

    // MARK: - Input level meter

    /// Streams mic level so the user can confirm the mic is not just detected but
    /// actually hearing, and can match channel levels before measuring.
    private func startInputLevel() throws {
        if levelTapped { return }
        guard ensureRecordPermission() else { throw CaptureError.noPermission }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothA2DP])
        if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? session.setPreferredInput(usb)
        }
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] b, _ in
            guard let self = self, let src = b.floatChannelData?[0] else { return }
            let n = Int(b.frameLength)
            guard n > 0 else { return }
            var sum = 0.0
            var peak = 0.0
            for i in 0..<n {
                let v = Double(src[i])
                sum += v * v
                peak = max(peak, abs(v))
            }
            let rms = (sum / Double(n)).squareRoot()
            // Throttle to ~20 Hz; a meter updated per buffer just burns battery.
            // But never drop a buffer while streaming samples: the analyser
            // concatenates them, so a gap splices the waveform and puts a
            // discontinuity through the FFT that looks like broadband noise.
            let now = Date()
            if !self.sendBlocks {
                guard now.timeIntervalSince(self.lastLevelSent) > 0.05 else { return }
            }
            self.lastLevelSent = now
            var payload: [String: Any] = [
                "rmsDb": RewAudioPlugin.dbfs(rms),
                "peakDb": RewAudioPlugin.dbfs(peak),
            ]
            if self.sendBlocks {
                // float32 little-endian, matching the Android side so the Dart
                // decoding is shared.
                var floats = [Float](repeating: 0, count: n)
                for i in 0..<n { floats[i] = src[i] }
                let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
                payload["samples"] = FlutterStandardTypedData(bytes: data)
                payload["fs"] = b.format.sampleRate
            }
            DispatchQueue.main.async { self.levelSink?(payload) }
        }
        levelTapped = true
        engine.prepare()
        if !engine.isRunning { try engine.start() }
    }

    private func stopInputLevel() {
        sendBlocks = false
        guard levelTapped else { return }
        engine.inputNode.removeTap(onBus: 0)
        levelTapped = false
        if !tonePlaying && engine.isRunning { engine.stop() }
    }

    // MARK: - Centring tone

    /// Loops a noise buffer so the user can centre the stage by ear while
    /// setting delays. Playback only — nothing is measured from it.
    private func startTone(samples: [Double], fs: Double) throws {
        stopTone()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default,
                                options: [.allowBluetoothA2DP])
        try session.setActive(true)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: fs, channels: 1,
                                   interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        let dst = buf.floatChannelData![0]
        for i in 0..<samples.count { dst[i] = Float(samples[i]) }

        if tonePlayer.engine == nil { engine.attach(tonePlayer) }
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: format)
        engine.prepare()
        if !engine.isRunning { try engine.start() }
        tonePlayer.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        tonePlayer.play()
        tonePlaying = true
    }

    private func stopTone() {
        guard tonePlaying else { return }
        tonePlayer.stop()
        tonePlaying = false
        if !levelTapped && engine.isRunning { engine.stop() }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Level stream

    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        levelSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        levelSink = nil
        return nil
    }

    // MARK: - Helpers

    private static func dbfs(_ amplitude: Double) -> Double {
        return amplitude <= 1e-9 ? -120.0 : 20.0 * log10(amplitude)
    }

    private static func decodeF64(_ data: Data) -> [Double] {
        let count = data.count / MemoryLayout<Double>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Double] in
            let base = raw.bindMemory(to: Double.self)
            return Array(UnsafeBufferPointer(start: base.baseAddress, count: count))
        }
    }
}
