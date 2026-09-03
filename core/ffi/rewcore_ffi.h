// C ABI for binding rewcore into Flutter via dart:ffi (and any other FFI host).
// Kept intentionally small and POD-only; the rich C++ API lives in rewcore/*.hpp.
#ifndef REWCORE_FFI_H
#define REWCORE_FFI_H

#include <stddef.h>

// Every entry point is looked up at run time by the Dart side and is never
// called from native code, so nothing in the app references these symbols at
// link time. On iOS the core is linked as a static library into the app binary,
// and an unreferenced symbol is simply dropped — the app builds cleanly and then
// cannot measure anything. `used` keeps the compiler from discarding it and
// `visibility("default")` keeps it in the binary's exported symbol table, which
// is where DynamicLibrary.process() looks.
#if defined(_WIN32)
#define REW_EXPORT __declspec(dllexport)
#else
#define REW_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Version string of the core, e.g. "0.1.0".
REW_EXPORT const char* rew_version(void);

// Generate an exponential sine sweep into a caller-allocated buffer.
// Returns the number of samples written (0 if `out` is null or `cap` too small to
// hold the whole sweep; call once with out=NULL to query the required length).
REW_EXPORT size_t rew_generate_sweep(double fs, double f1, double f2, double durationSec,
                          double* out, size_t cap);

// RMS level of a buffer in dBFS (full-scale sine reads -3.01 dBFS). Add an SPL
// calibration offset to get dB SPL; relative levels need no offset.
REW_EXPORT double rew_rms_dbfs(const double* samples, size_t n);

// Generate one loopable block of pink noise, optionally band-limited to
// [fLo, fHi] (pass 0 for either to skip that side). Used for judging the centre
// image by ear during manual time alignment. Call with out=NULL to query length.
REW_EXPORT size_t rew_generate_noise(double fs, double durationSec, double fLo, double fHi,
                          double amplitude, unsigned int seed, double* out,
                          size_t cap);

// Measure a magnitude frequency response from an emitted stimulus and a recording.
// Writes up to `cap` (freq, magDb) pairs into freqOut/magOut on a log grid over
// [fMin, fMax] after 1/`smoothFrac`-octave smoothing. Returns the number of points
// written. `points` requests the grid density (clamped to cap).
//
// If `calN` > 0, a UMIK-1 microphone calibration (parallel calFreq/calGain arrays) is
// applied to the response. Pass calFreq/calGain = NULL and calN = 0 to skip.
// `phaseOut` may be NULL; when given it receives the UNWRAPPED phase in degrees.
// Set `timeReferencePhase` to remove the bulk flight time before computing phase
// (what you want for display); leave it 0 to measure the delay itself.
REW_EXPORT size_t rew_measure_fr(const double* emitted, size_t emittedLen,
                      const double* recorded, size_t recordedLen, double fs,
                      double fMin, double fMax, double smoothFrac, size_t points,
                      const double* calFreq, const double* calGain, size_t calN,
                      int timeReferencePhase, double* freqOut, double* magOut,
                      double* phaseOut, size_t cap);

// Fit up to `maxBands` parametric EQ bands to move `measured` toward a flat target.
// Inputs are parallel freq/mag arrays of length `n`. Writes chosen bands into the
// parallel freq/gain/q output arrays (capacity `maxBands`) and returns the band count.
// If `errOut` is non-NULL it receives {initialErrorDb, finalErrorDb} (2 doubles).
// `targetPercentile` places the flat target within the usable band's level
// distribution: low values cut peaks hard (flatter, but the whole response ends
// up quieter), high values correct gently. Pass 0 for the default (0.25).
REW_EXPORT size_t rew_fit_peq_flat(const double* freq, const double* mag, size_t n, double fs,
                        double fMin, double fMax, int maxBands,
                        double targetPercentile, double* freqOut,
                        double* gainOut, double* qOut, double* errOut);

// Recommend crossover edges for one measured driver (parallel freq/mag, length `n`).
// Writes the high-pass edge to hpOut and low-pass edge to lpOut (Hz). Returns a bit
// mask: bit0 set => high-pass suggested, bit1 set => low-pass suggested.
REW_EXPORT int rew_recommend_crossover(const double* freq, const double* mag, size_t n,
                            double dropDb, double* hpOut, double* lpOut);

#ifdef __cplusplus
}
#endif

#endif  // REWCORE_FFI_H
