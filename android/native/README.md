# Android native audio layer

> **The implementation now lives in the app**, wired up and ready to build:
> `app/android/app/src/main/kotlin/com/rewmobile/audio/RewAudioPlugin.kt`,
> registered on the `rew_mobile/audio` channel from
> `app/android/app/src/main/kotlin/com/example/rew_mobile/MainActivity.kt`.
> Permissions (`RECORD_AUDIO`, `usb.host`) are in the app's `AndroidManifest.xml`.
> This directory is kept for design notes only.

## Responsibilities

- **UMIK-1 input over USB.** The UMIK-1 is a USB Audio Class 1 device. The current
  implementation captures it with `AudioRecord` pinned to the USB input via
  `setPreferredDevice()`, preferring an `UNPROCESSED` source (falling back to
  `VOICE_RECOGNITION`/`MIC`) so no AGC or noise suppression corrupts the measurement.
- **Sweep output.** `AudioTrack` with `USAGE_MEDIA`, so the sweep routes out over
  wireless Android Auto / A2DP to the OEM head unit while the mic records.
- **Simultaneous play + record** — the phone's single USB port is taken by the mic, so
  output must be wireless. That is by design.

## Fallback if AudioRecord can't see the mic

Android's native UAC support is inconsistent across devices. If a given phone won't
expose the UMIK-1 to `AudioRecord`, the fallback is a **libusb-based UAC isochronous
IN driver** in the NDK (`UsbManager` + permission intent → claim the audio-streaming
interface → isochronous transfers). Try the `AudioRecord` path first — it is far
simpler and works on many devices.

## Notes

- Keep captured PCM in float and hand raw buffers to `rewcore`; **no DSP here**.
- Validate on a real device (Spike #0) before trusting any numbers.
