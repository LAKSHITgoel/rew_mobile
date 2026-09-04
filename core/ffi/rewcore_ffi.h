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

// Per-point standard deviation, in dB, across `count` responses of `n` points
// each (magnitudes laid out contiguously). This is measurement repeatability;
// feed it to rew_fit_peq so unrepeatable features are not "corrected".
// Re-smooth a stored response, for changing smoothing on a measurement that has
// already been taken. Note it can only ever coarsen: the stored curve is
// already smoothed, and nothing here can recover detail that was averaged away
// when it was measured.
REW_EXPORT size_t rew_smooth_response(const double* freq, const double* mag,
                                      size_t n, double fractionOfOctave,
                                      double* out);

REW_EXPORT size_t rew_response_spread(const double* mags, size_t count, size_t n,
                                      double* out);

// Check a raw capture before anything is inferred from it. `out` receives six
// doubles: peak, rmsDbfs, clippedFraction, silentFraction, flags, usable.
// `flags` is a bitmask: 1 clipped, 2 too quiet, 4 mostly silent.
REW_EXPORT int rew_assess_capture(const double* samples, size_t n, double fs,
                                  double* out);

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
// Measure a frequency response, returning TWO curves on the same grid.
//
// The display curve is smoothed however the user likes; the analysis curve is
// smoothed at a fixed, fine setting and is what the EQ fitter reads. They are
// separated because the two jobs disagree: heavy smoothing is right for reading
// tonal balance by eye and wrong for deciding filters, since it hides the shape
// of what is being corrected.
//
// Note the analysis curve is *lightly smoothed*, not raw. Point-sampling a raw
// FFT onto a few hundred log-spaced bins is not "more honest" — it decimates a
// dense noisy spectrum and the values that survive are close to arbitrary.
// Smoothing narrower than the grid spacing is the actual goal.
typedef struct rew_measure_request {
  const double* emitted;
  const double* recorded;
  const double* calFreq;   // optional mic calibration
  const double* calGain;   // optional, paired with calFreq
  size_t emittedLen;
  size_t recordedLen;
  size_t calN;
  size_t points;
  double fs;
  double fMin;
  double fMax;
  double smoothFrac;          // display smoothing; 0 means none
  double analysisSmoothFrac;  // fitting smoothing; 0 keeps the built-in default
  int timeReferencePhase;
  int reserved_;

  double* freqOut;
  double* magOut;          // display curve
  double* magAnalysisOut;  // fitting curve (optional)
  double* phaseOut;        // optional
  size_t cap;
} rew_measure_request;

REW_EXPORT size_t rew_measure_fr(const rew_measure_request* req);

// sizeof(rew_measure_request), so a binding can assert its layout agrees.
REW_EXPORT size_t rew_measure_request_size(void);

// Fit up to `maxBands` parametric EQ bands to move `measured` toward a flat target.
// Inputs are parallel freq/mag arrays of length `n`. Writes chosen bands into the
// parallel freq/gain/q output arrays (capacity `maxBands`) and returns the band count.
// If `errOut` is non-NULL it receives {initialErrorDb, finalErrorDb} (2 doubles).
// `targetPercentile` places the flat target within the usable band's level
// distribution: low values cut peaks hard (flatter, but the whole response ends
// up quieter), high values correct gently. Pass 0 for the default (0.25).
// Fit EQ, and say why.
//
// Passed as a struct rather than as positional arguments: this call had grown
// to nineteen of them, most of them pointers or doubles, so any two transposed
// still compiled and quietly computed nonsense. Named fields make that a
// compile error, and adding a parameter no longer changes the arity for every
// caller.
typedef struct rew_peq_request {
  // --- measurement ---
  const double* freq;          // length n
  const double* mag;           // length n, dB
  // Optional, length n. Points marked 0 are excluded from the fit entirely:
  // use it to drop anything the sweep did not lift clear of the noise.
  const unsigned char* valid;
  // Optional, length n. Per-point standard deviation across repeated captures
  // (see rew_response_spread). Supplying it lets the fitter tell a property of
  // the car from something that happened once.
  const double* spread;
  size_t n;

  // --- constraints ---
  double fs;
  double fMin;
  double fMax;
  double targetPercentile;  // 0 keeps the built-in default
  double maxCutDb;          // 0 keeps the built-in default
  double maxBoostDb;        // 0 keeps the built-in default
  int maxBands;
  int reserved_;            // explicit padding, so the layout is unambiguous

  // --- target curve ---
  // Flat is not the goal in a car. All zero means flat; see TargetShape in
  // peq.hpp for what these mean.
  double bassShelfDb;
  double bassShelfHz;       // 0 keeps the built-in default
  double bassShelfWidthOct; // 0 keeps the built-in default
  double tiltDbPerOctave;
  double tiltPivotHz;       // 0 keeps the built-in default

  // --- outputs, all caller-allocated ---
  double* freqOut;      // maxBands
  double* gainOut;      // maxBands
  double* qOut;         // maxBands
  int* reasonOut;       // maxBands, PeqReason codes (optional)
  double* confOut;      // maxBands, 0..1 (optional)
  // Interleaved (reasonCode, frequency) pairs for features deliberately left
  // alone; up to declinedCap pairs. The count comes back in errOut[3].
  double* declinedOut;
  size_t declinedCap;
  // At least 4 doubles: initial error, final error, suggested level trim,
  // number of declined entries written.
  double* errOut;
} rew_peq_request;

REW_EXPORT size_t rew_fit_peq(const rew_peq_request* req);

// sizeof(rew_peq_request), so a binding in another language can assert its own
// layout matches. A struct ABI turns a transposed argument into a compile
// error, but it turns a mismatched layout into silent corruption — this is how
// the Dart side proves it agrees.
REW_EXPORT size_t rew_peq_request_size(void);

// Recommend crossover edges for one measured driver (parallel freq/mag, length `n`).
// Writes the high-pass edge to hpOut and low-pass edge to lpOut (Hz). Returns a bit
// mask: bit0 set => high-pass suggested, bit1 set => low-pass suggested.
// Crossover advice for one measured driver.
//
// Struct-passed for the same reason the others are, and because a crossover
// recommendation is not one number: it is a frequency, the slope the driver
// already gives on its own, the slope to set in the DSP to reach the target
// alignment, a confidence, and a reason.
typedef struct rew_crossover_edge {
  int present;
  int reason;                        // rewcore::CrossoverReason
  double freqHz;                     // measured -dropDb point
  double recommendedHz;              // with the safety margin applied
  double acousticSlopeDbPerOct;      // what the driver already does
  double electricalSlopeDbPerOct;    // what to set in the DSP
  double confidence;                 // 0..1
} rew_crossover_edge;

typedef struct rew_crossover_result {
  rew_crossover_edge highPass;
  rew_crossover_edge lowPass;
  double passbandDb;
} rew_crossover_result;

REW_EXPORT int rew_recommend_crossover(const double* freq, const double* mag,
                                       size_t n, double dropDb,
                                       double targetAcousticDbPerOct,
                                       double marginOctaves,
                                       rew_crossover_result* out);

// sizeof(rew_crossover_result), for the same layout assertion as the others.
REW_EXPORT size_t rew_crossover_result_size(void);

// Whether two drivers are working together through their crossover.
//
// Magnitude only — no phase, and no assumption that the sweep arrived when it
// was expected to. That is what makes it usable over a wireless link, where
// absolute arrival time is not stable enough to trust.
typedef struct rew_summation_result {
  int valid;
  int haveInverted;
  int advice;            // rewcore::PolarityAdvice
  int reserved_;
  double overlapLoHz;
  double overlapHiHz;
  double measuredDb;
  double invertedDb;
  double coherentDb;
  double powerDb;
  double deficitDb;
  double invertedGainDb;
  double confidence;
} rew_summation_result;

// All four responses share one frequency grid of `n` points. `bothInverted` may
// be null if that measurement was not taken.
REW_EXPORT int rew_analyze_summation(const double* freq, const double* aMag,
                                     const double* bMag, const double* bothMag,
                                     const double* bothInvertedMag, size_t n,
                                     double overlapDropDb,
                                     rew_summation_result* out);

REW_EXPORT size_t rew_summation_result_size(void);

// ---------------------------------------------------------------------------
// Real-time analyser.
//
// Stateful, unlike everything else here: it accumulates blocks, overlaps and
// windows them, and averages over time. So it is an opaque handle rather than a
// pure call. Create one, push audio as it arrives, read the spectrum whenever
// you want to draw, destroy it when done.
// ---------------------------------------------------------------------------
typedef struct rew_rta_config {
  double fs;
  double overlap;        // 0 keeps the default
  double smoothFrac;     // <0 means none; 0 keeps the default
  double fMin;
  double fMax;
  double bandsPerOctave; // 0 keeps the default
  // Optional microphone calibration, applied to the spectrum exactly as it is
  // to a swept measurement. Without it the display shows the microphone's own
  // response as much as the car's.
  const double* calFreqHz;
  const double* calGainDb;
  size_t calN;
  size_t fftSize;        // 0 keeps the default
  size_t points;         // 0 keeps the raw FFT grid
  int averagingMode;     // 0 none, 1 exponential, 2 forever
  int averageCount;      // spectra in the running average (1, 2, 4, 8, ...)
  int octaveBands;       // draw 1/N octave bands rather than FFT lines
  int weighting;         // 0 Z, 1 A, 2 C — for the level readout
  int pinkWeighted;
  int reserved_;
} rew_rta_config;

typedef struct rew_rta rew_rta;

REW_EXPORT rew_rta* rew_rta_create(const rew_rta_config* cfg);
REW_EXPORT void rew_rta_destroy(rew_rta* rta);

// Feed captured samples; returns how many new spectra were folded in.
REW_EXPORT size_t rew_rta_push(rew_rta* rta, const double* samples, size_t n);

// Current time-averaged spectrum. Returns the number of points written.
REW_EXPORT size_t rew_rta_spectrum(rew_rta* rta, double* freqOut, double* magOut,
                                   size_t cap);
// Highest level seen at each frequency since the last reset.
REW_EXPORT size_t rew_rta_peak_hold(rew_rta* rta, double* freqOut,
                                    double* magOut, size_t cap);

REW_EXPORT double rew_rta_level_dbfs(rew_rta* rta);
REW_EXPORT void rew_rta_reset(rew_rta* rta, int averaging, int peakHold);

REW_EXPORT size_t rew_rta_config_size(void);

#ifdef __cplusplus
}
#endif

#endif  // REWCORE_FFI_H
