# iOS native audio layer (M2)

The only iOS-specific code. Exposes a small Flutter plugin surface; all DSP goes through
`rewcore` (compiled for iOS).

## Responsibilities

- **UMIK-1 input over USB.** iOS forbids custom USB drivers, so rely on the OS exposing
  the UMIK-1 (via a USB-C / Lightning **camera adapter**) as a standard input. Use
  `AVAudioSession` with category `.playAndRecord`, set the UMIK-1 as `preferredInput`,
  and confirm the input format. (This is how AudioTools / SignalScope use it.)
- **Sweep output.** Play the generated sweep as normal media so it routes out over
  wireless CarPlay / A2DP to the OEM head unit, while input comes from the USB mic.
- **Capture** via `AVAudioEngine` input tap; hand float buffers straight to `rewcore`.
- **Calibration file import** via `UIDocumentPickerViewController`.

## Reference implementation

`RewAudioPlugin.swift` implements the `rew_mobile/audio` channel: `.playAndRecord`
with `.allowBluetoothA2DP`, preferred input set to the `.usbAudio` port, an
`AVAudioPlayerNode` for the sweep and an input-node tap for capture. Needs on-device
validation — especially that output routes to CarPlay/BT while input stays on USB.

## Notes

- Add `NSMicrophoneUsageDescription`.
- Verify in Spike #0 that the session will route **output to CarPlay/BT while input is
  the USB mic** — the two ports are independent but the routing needs confirming on real
  hardware.
- Do not implement any DSP here; keep this layer to I/O + routing only.
