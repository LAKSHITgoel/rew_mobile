# rew_mobile

A cross-platform (Android + iOS) app to measure and tune car audio from the phone,
using a miniDSP **UMIK-1** USB measurement microphone.

## Why

Tuning a car DSP normally means a laptop (REW), a USB mic, and a phone (the DSP's app).
The catch: a laptop can usually only reach the DSP over a link that **bypasses the OEM
head unit**, so it measures a signal chain you never actually listen to. But the *phone*
is the CarPlay / Android Auto source — so if the app plays its measurement sweep as
ordinary **media audio**, that sweep travels the real chain (OEM "lift-to-dashboard"
processing and the aftermarket DSP included). That is the whole reason to do this on the
phone, and it's what a laptop can't do.

The second goal is speed: automate the per-driver measurement sequence and the
sweep-reading/analysis that currently turns a tune into a 5–6 hour job.

## Scope (v1)

- **Measure + recommend.** The app measures and outputs the exact settings (parametric
  EQ bands, crossover points/slopes) to type into your DSP's own app. It does **not**
  drive the DSP directly in v1 (no public control protocol for the target hardware).
- **Guided wizard: level → crossovers → EQ → verify.**
- **Time alignment is intentionally out of scope for v1.** It's the one stage that needs
  stable, known timing, and the wireless OEM/Bluetooth output path has variable latency
  that makes delay measurement unreliable. Crossovers and EQ depend only on magnitude
  and are unaffected by that latency.

See [`docs/`](docs/) / the planning notes for the full rationale.

## Architecture

Three layers, so the hard DSP is written once and only the fiddly audio I/O is native:

| Layer | Path | What it is |
|-------|------|------------|
| **Measurement core** | [`core/`](core/) | Platform-agnostic C++ DSP — the source of truth for correctness. No OS audio APIs. Compiles for Android (NDK), iOS, and desktop (tests). |
| **C ABI** | [`core/ffi/`](core/ffi/) | Small `extern "C"` surface for binding into Flutter via `dart:ffi`. |
| **Native audio + USB** | [`android/native/`](android/native/), [`ios/native/`](ios/native/) | The only platform-specific code: simultaneous sweep-out / UMIK-1-in, device routing. |
| **UI** | [`app/`](app/) | Flutter: wizard, live FR graphs, project storage, "DSP entry" output sheets. |
| **Desktop harness** | [`tools/`](tools/) | Runs the core against recorded/synthetic WAVs (also the CI test target). |

## Build & test the core (no hardware needed)

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
# or run the harness directly:
./build/core/rewcore_tests
```

The test harness synthesizes signals with known answers (a known delay, a known biquad,
a bumpy response to flatten, a Linkwitz-Riley crossover) and asserts the DSP recovers
them — so the measurement math is verified without a mic or a car.

## Status / roadmap

- [x] **M1 — Core DSP on desktop.** Sweep generation, regularized deconvolution → impulse
      response → frequency response, fractional-octave smoothing, spatial averaging,
      mic-calibration parse/apply, parametric-EQ auto-fit, crossover summation check,
      WAV I/O, C ABI. Unit-tested.
- [ ] **M2 — Flutter app + FFI + one real measurement** through the native audio layer.
- [ ] **M3 — Guided wizard** (crossovers → EQ) + DSP-entry sheets + project save/report.
- [ ] **M4 — Field tuning & polish** in the car; compare against a hand-tuned baseline.
- [ ] **Spike #0 — Audio path proof** (do before M2): on both OSes, simultaneously play a
      sweep out wirelessly and capture the UMIK-1 over USB; confirm a clean IR.
