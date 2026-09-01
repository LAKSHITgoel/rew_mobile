# rewcore

Platform-agnostic C++17 measurement DSP. No OS audio APIs — this is the single source
of truth for measurement correctness, compiled into a native library for Android (NDK)
and iOS, and built for desktop to run the tests.

## Modules (`include/rewcore/`)

| Header | Responsibility |
|--------|----------------|
| `fft.hpp` | Radix-2 FFT / inverse, real-input helpers. Dependency-free. |
| `dsp.hpp` | Exponential sine sweep (Farina), regularized deconvolution → impulse response, IR peak find, magnitude frequency response, fractional-octave smoothing, log resampling, spatial averaging. |
| `biquad.hpp` | RBJ cookbook biquads (peaking / shelves) and their magnitude response; PEQ-band cascade magnitude. |
| `peq.hpp` | Target curves (flat / tilt) and a greedy parametric-EQ **auto-fit** constrained to the DSP's band/gain/Q limits. |
| `crossover.hpp` | Butterworth / Linkwitz-Riley branch magnitudes and a crossover **summation flatness** check. |
| `calibration.hpp` | Parse a miniDSP-style UMIK-1 calibration `.txt` and apply it to a measurement. |
| `wav.hpp` | Minimal WAV read (PCM16 / float32, any channel count → mono) and mono-float write. |

## Measurement flow

```
sweep (generateExpSweep)  ──play──▶  [car + DSP + room]  ──UMIK-1──▶  recording
                                                                        │
              recording ─┬─ deconvolve(emitted, recorded) ─▶ impulse response
                         │
   impulse response ─▶ frequencyResponse ─▶ smoothFractionalOctave ─▶ applyMicCalibration
                         │
       (many positions) ─▶ spatialAverage ─▶ fitPeq(measured, target) ─▶ PEQ bands
```

Deconvolution uses frequency-domain division with regularization
(`H = Y·conj(X) / (|X|² + ε)`), which is exact for a linear path and immune to the
sweep's spectral tilt — preferred over a raw time-reversed inverse filter.

## C ABI (`ffi/rewcore_ffi.h`)

`rew_version`, `rew_generate_sweep`, `rew_measure_fr`, `rew_fit_peq_flat` — a small
POD-only surface for `dart:ffi`. The rich C++ API stays in the headers above.

## Tests

`tests/test_rewcore.cpp` — a self-contained harness (no external framework) asserting
the pipeline recovers known answers. Build from the repo root and run
`./build/core/rewcore_tests` or `ctest --test-dir build`.
