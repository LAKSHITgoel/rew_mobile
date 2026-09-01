// iOS reference implementation of the `rew_mobile/audio` MethodChannel.
//
// STATUS: reference implementation — needs validation on real hardware. Drop this
// into the Flutter plugin's ios/Classes tree and register the channel from the
// plugin's `register(with:)`.
//
// Strategy:
//   * Session: .playAndRecord with .allowBluetoothA2DP so the sweep can go out over
//     wireless CarPlay / A2DP (high quality) to the OEM head unit while we record.
//   * Input: pick the USB audio input (portType == .usbAudio) as the preferred input
//     — the UMIK-1 via a USB-C / Lightning camera adapter appears here.
//   * Engine: AVAudioPlayerNode plays the sweep buffer; an input-node tap captures
//     the mic. Both share the engine's sample rate.
//
// Validate on hardware that output actually routes to the car while input stays on
// the USB mic (the two ports are independent, but routing needs confirming).
import AVFoundation
import Flutter

public class RewAudioPlugin: NSObject, FlutterPlugin {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "rew_mobile/audio", binaryMessenger: registrar.messenger())
        let instance = RewAudioPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "micStatus":
            result(micStatus())
        case "playSweepAndCapture":
            guard let args = call.arguments as? [String: Any],
                  let data = (args["sweep"] as? FlutterStandardTypedData)?.data,
                  let fs = args["fs"] as? Double else {
                result(FlutterError(code: "ARG", message: "missing sweep/fs", details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let sweep = Self.decodeF64(data)
                    let rec = try self.playAndCapture(sweep: sweep, fs: fs)
                    let bytes = rec.withUnsafeBufferPointer { Data(buffer: $0) }
                    DispatchQueue.main.async {
                        result(FlutterStandardTypedData(float64: bytes))
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "CAPTURE",
                                            message: error.localizedDescription, details: nil))
                    }
                }
            }
        case "dispose":
            engine.stop()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func micStatus() -> [String: Any?] {
        let session = AVAudioSession.sharedInstance()
        let usb = session.availableInputs?.first { $0.portType == .usbAudio }
        return ["connected": usb != nil, "name": usb?.portName]
    }

    private func playAndCapture(sweep: [Double], fs: Double) throws -> [Double] {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                options: [.allowBluetoothA2DP, .mixWithOthers])
        if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try session.setPreferredInput(usb)
        }
        try session.setActive(true)

        let sr = engine.inputNode.inputFormat(forBus: 0).sampleRate
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sr, channels: 1, interleaved: false)!

        // Build the sweep buffer at the engine's sample rate (assumes fs == sr; a
        // resampler belongs here if they differ).
        let frames = AVAudioFrameCount(sweep.count)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<sweep.count { ch[i] = Float(sweep[i]) }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        var captured = [Double]()
        captured.reserveCapacity(sweep.count + Int(sr * 0.3))
        let lock = NSLock()

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { b, _ in
            let p = b.floatChannelData![0]
            lock.lock()
            for i in 0..<Int(b.frameLength) { captured.append(Double(p[i])) }
            lock.unlock()
        }

        try engine.start()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()

        // Capture for the sweep plus a tail.
        let seconds = Double(sweep.count) / sr + 0.3
        Thread.sleep(forTimeInterval: seconds)

        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        return captured
    }

    private static func decodeF64(_ data: Data) -> [Double] {
        let count = data.count / MemoryLayout<Double>.size
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: Double.self),
                count: count))
        }
    }
}
