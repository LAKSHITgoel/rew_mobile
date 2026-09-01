// C ABI for binding rewcore into Flutter via dart:ffi (and any other FFI host).
// Kept intentionally small and POD-only; the rich C++ API lives in rewcore/*.hpp.
#ifndef REWCORE_FFI_H
#define REWCORE_FFI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version string of the core, e.g. "0.1.0".
const char* rew_version(void);

// Generate an exponential sine sweep into a caller-allocated buffer.
// Returns the number of samples written (0 if `out` is null or `cap` too small to
// hold the whole sweep; call once with out=NULL to query the required length).
size_t rew_generate_sweep(double fs, double f1, double f2, double durationSec,
                          double* out, size_t cap);

// Measure a magnitude frequency response from an emitted stimulus and a recording.
// Writes up to `cap` (freq, magDb) pairs into freqOut/magOut on a log grid over
// [fMin, fMax] after 1/`smoothFrac`-octave smoothing. Returns the number of points
// written. `points` requests the grid density (clamped to cap).
size_t rew_measure_fr(const double* emitted, size_t emittedLen,
                      const double* recorded, size_t recordedLen, double fs,
                      double fMin, double fMax, double smoothFrac, size_t points,
                      double* freqOut, double* magOut, size_t cap);

// Fit up to `maxBands` parametric EQ bands to move `measured` toward a flat target.
// Inputs are parallel freq/mag arrays of length `n`. Writes chosen bands into the
// parallel freq/gain/q output arrays (capacity `maxBands`) and returns the band count.
size_t rew_fit_peq_flat(const double* freq, const double* mag, size_t n, double fs,
                        double fMin, double fMax, int maxBands, double* freqOut,
                        double* gainOut, double* qOut);

#ifdef __cplusplus
}
#endif

#endif  // REWCORE_FFI_H
