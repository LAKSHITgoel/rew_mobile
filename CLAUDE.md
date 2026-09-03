# CLAUDE.md — rew_mobile

Guidance for working in this repo. See `README.md` for the product overview.

## What this is

A cross-platform app to measure and tune car audio from a phone with a miniDSP UMIK-1
USB mic. The phone plays a measurement sweep out over wireless CarPlay/Android Auto/BT
(so it passes through the real OEM + DSP chain) and captures the mic over USB; a guided
wizard recommends crossover and parametric-EQ settings to enter into the car's DSP app.

**Scope:** crossovers + EQ only (magnitude domain). Time alignment is deliberately out
(wireless latency is unstable). The app recommends settings; it does not drive the DSP.

## Layout

```
core/           C++17 measurement DSP — the source of truth. No OS audio APIs.
  ffi/          C ABI (rew_*) for dart:ffi
  tests/        self-contained harness (ctest)
tools/          rewcli — desktop CLI over the core (sweep|measure|eq|xover)
packages/
  rewcore_ffi/  Flutter FFI plugin: compiles core/ into a loadable native lib
app/            Flutter app (lib/ + test/); mock audio backend runs with no hardware
  android/      Android host build; the Kotlin audio plugin lives here, wired to the
                `rew_mobile/audio` channel (com/rewmobile/audio/RewAudioPlugin.kt)
android/native/ Android design notes + libusb fallback plan (no code)
ios/native/     Swift audio plugin (AVAudioEngine + AVAudioSession) — reference
```

## Build & test

**C++ core + CLI (verified in CI):**
```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure     # or ./build/core/rewcore_tests
```
CLI smoke:
```sh
./build/tools/rewcli sweep /tmp/sweep.wav --dur 2
./build/tools/rewcli measure --emitted /tmp/sweep.wav --recorded rec.wav --cal umik.txt
./build/tools/rewcli eq --emitted /tmp/sweep.wav --recorded rec.wav --bands 10
```

**Flutter app (needs the SDK; bootstrap once):**
```sh
cd app
flutter create --platforms=android,ios,linux,macos,windows .
flutter pub get
flutter test            # pure-Dart unit tests in app/test/
flutter analyze
flutter run --dart-define=USE_MOCK_AUDIO=true   # no mic/car needed
```

## Conventions & guardrails

- **All DSP lives in `core/` (C++).** Dart mirrors (e.g. `services/dsp_math.dart`,
  `crossover_calc.dart`) are for interactive previews only — keep them consistent with
  the C++, which is the authority. Do not add measurement math to Dart or native code.
- **Native layers do I/O only** (capture + playback + routing); they hand raw float
  buffers to `rewcore`.
- Keep the C ABI (`core/ffi/rewcore_ffi.h`) and the Dart bindings
  (`app/lib/src/ffi/rewcore_bindings.dart`) in sync; `dart run ffigen` can regenerate.
- Add a unit test for any new `core/` function (see `core/tests/test_rewcore.cpp`).

## Status boundary (important)

- **Verified here:** `core/` + `tools/` (compiled, 43 ctest checks); `app/` Dart
  (`flutter analyze` clean, 16 tests pass) and `packages/rewcore_ffi/` (its
  `src/CMakeLists.txt` builds `librewcore_ffi` exporting all 5 `rew_*` symbols).
- **The Dart↔C ABI is verified end-to-end** by `app/test/ffi_smoke_test.dart`, which
  loads the real compiled library and checks every `rew_*` entry point (including
  calibration-array marshaling and out-params). Build it first, or the test skips:
  `cmake -S packages/rewcore_ffi/src -B build-ffi && cmake --build build-ffi -j`.
- **Written, needs the Android SDK/NDK (or Xcode + CocoaPods) to compile:** the Android
  and iOS/macOS host builds of `app/` and `packages/rewcore_ffi/`.
- **Written, needs a device to validate:** the Kotlin/Swift audio layers, and above
  all **Spike #0** — proving simultaneous wireless-sweep-out + USB-mic-in gives a clean
  measurement. Do that before trusting any on-device numbers.
