# Android native audio + USB layer (M2)

The only Android-specific code. Exposes a small Flutter plugin surface; all DSP goes
through `rewcore` (built here with the NDK).

## Responsibilities

- **UMIK-1 input over USB.** The UMIK-1 is a USB Audio Class 1 device, but Android's
  native UAC handling is inconsistent across devices, so ship a **USB-host UAC driver**:
  `UsbManager` + permission intent → claim the audio-streaming interface → isochronous
  IN transfers (libusb through the NDK is the pragmatic route). This is the single
  hardest native task — de-risk it in Spike #0.
- **Sweep output.** Play the generated sweep as normal **media** so it routes out over
  wireless Android Auto / A2DP to the OEM head unit. Oboe/AAudio for low-overhead
  playback.
- **Simultaneous play + record** with the mic on USB and audio going out wirelessly
  (the phone's single USB port is taken by the mic — this is by design).
- **Calibration file import** via the Storage Access Framework.

## Notes

- Request `android.permission.RECORD_AUDIO` and declare `<uses-feature usb.host>`.
- Keep the driver's captured PCM in float and hand raw buffers to `rewcore` — do not
  duplicate any DSP here.
