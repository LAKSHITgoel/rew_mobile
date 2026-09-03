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
  ios/          iOS host build; the Swift audio and files plugins live in Runner/
                (RewAudioPlugin.swift, RewFilesPlugin.swift), registered by hand
                in AppDelegate — they are app code, not a pub plugin
android/native/ Android design notes + libusb fallback plan (no code)
ios/native/     Earlier Swift sketch, kept as notes; app/ios/Runner is the real one
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
- **Android is verified on a device:** debug and release builds install and run on
  a phone; a measurement plays a real sweep and captures the mic end to end.
- **Nothing iOS has been compiled.** The Swift audio/files plugins are written and
  registered in the Xcode project (both appear in the Runner target's Sources
  phase, and the project still parses), but this machine has only the Command
  Line Tools — no Xcode, no CocoaPods — so none of it has seen a compiler. Treat
  every iOS claim as unverified until `flutter build ios` runs.
- **Recommendations explain themselves.** Every EQ band and crossover edge
  carries a reason code and a confidence score, and features the fitter refuses
  to touch come back as advice rather than being omitted. Confidence is a
  weighted geometric mean of width, depth, repeatability and edge proximity —
  never a product, which collapses to single digits and tells the user nothing.
- **A bad capture never becomes advice.** `assessCapture()` rejects clipped,
  silent and mostly-empty recordings before anything is inferred. Clipping means
  a flat top (consecutive samples pinned at the extreme), not merely touching
  full scale — a clean 0 dBFS sine is not clipped.
- **Two curves per measurement.** The display curve is smoothed however the user
  asks; the analysis curve is smoothed at a fixed fine setting and is what the
  fitter and the repeatability calculation read. Changing display smoothing must
  never change a recommendation.
- **Flat is not the target.** `TargetShape` (bass shelf + tilt above a pivot)
  and the presets in `TargetPreset` express what the listener wants; the choice
  is saved with the tune.
- **The three C ABI calls pass structs**, not long positional argument lists,
  and each exports a `*_size()` the Dart side asserts against. A struct ABI
  turns a transposed argument into a compile error but a mismatched layout into
  silent corruption, so the size check is not optional.
- The mock audio backend is **opt-in only** (`--dart-define=USE_MOCK_AUDIO=true`)
  and paints a banner while active. It must never become a default again: a debug
  build once used it silently and fabricated whole measurements.
- **Written, needs a device to validate:** the Kotlin/Swift audio layers, and above
  all **Spike #0** — proving simultaneous wireless-sweep-out + USB-mic-in gives a clean
  measurement. Do that before trusting any on-device numbers.
