# app — Flutter UI

The cross-platform app. One Dart codebase (`lib/`) that binds `rewcore` through
`dart:ffi` and talks to the native audio/USB plugins over a `MethodChannel`.

> **Status:** the Dart source is complete and self-consistent but has **not been
> compiled here** (no Flutter SDK in the build container). Bootstrap the platform
> folders with the Flutter SDK, then `flutter analyze` / `flutter run`.

## What's implemented (`lib/`)

```
main.dart                     app entry; picks mock vs native audio backend
src/
  app_services.dart           DI container (core + audio + store)
  ffi/
    rewcore_bindings.dart      dart:ffi typedefs for core/ffi/rewcore_ffi.h
    rewcore.dart              memory-safe wrapper (sweep / measure / fit PEQ)
  models/
    measurement.dart          FreqResponse, PeqBand, EqResult, Channel, slopes
    project.dart              TuneProject (JSON-serializable saved tune)
  audio/
    audio_backend.dart        interface: play sweep + capture from mic
    mock_audio_backend.dart   HARDWARE-FREE: synthesizes a car-like recording
    native_audio_backend.dart MethodChannel to the platform plugins
  services/
    measurement_service.dart  orchestrates sweep -> capture -> FR -> EQ fit
    crossover_calc.dart       LR/BW summation preview (pure Dart)
    dsp_math.dart             biquad magnitude for the "after EQ" preview
    project_store.dart        in-memory + file-backed persistence
  wizard/
    wizard_controller.dart    state machine: setup -> crossovers -> eq -> verify
  ui/
    home_screen.dart          project list + "new tune"
    wizard_screen.dart        the guided flow
    fr_chart.dart             log-frequency magnitude chart (CustomPainter)
    dsp_entry_sheet.dart      the deliverable: values to enter in the Alpine app
```

The app's DSP all runs in the native **rewcore** library via FFI — the Dart side only
marshals data and draws. The **mock audio backend** replaces the mic + car (not the
DSP), so the whole flow runs on a desktop/emulator build with no hardware.

## Bootstrap & run

```sh
cd app
# Generate the platform folders (android/, ios/, linux/, ...) around this lib/:
flutter create --platforms=android,ios,linux,macos,windows .
flutter pub get

# Run against the mock backend (no mic/car needed) — mock is the debug default,
# or force it explicitly:
flutter run --dart-define=USE_MOCK_AUDIO=true
```

## Wiring the native code (for real hardware)

1. Create an FFI plugin for the core and point its CMake/podspec at `../core` so
   `rewcore` (and its `extern "C"` symbols) link into the app:
   `flutter create --template=plugin_ffi --platforms=android,ios rewcore_ffi`.
   Regenerate Dart bindings with `dart run ffigen` against `core/ffi/rewcore_ffi.h`
   (the hand-written `rewcore_bindings.dart` can be replaced by the generated file).
2. Add the audio plugins: drop `android/native/RewAudioPlugin.kt` and
   `ios/native/RewAudioPlugin.swift` into a platform plugin and register the
   `rew_mobile/audio` channel. Set `USE_MOCK_AUDIO=false` to use them.
3. Permissions: Android `RECORD_AUDIO` + `<uses-feature usb.host>`; iOS
   `NSMicrophoneUsageDescription`.
