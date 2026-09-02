#pragma once
#include <cstddef>
#include <vector>

namespace rewcore {

// ---- Stimulus -------------------------------------------------------------

struct SweepSpec {
  double fs = 48000.0;   // sample rate
  double f1 = 20.0;      // start frequency (Hz)
  double f2 = 20000.0;   // end frequency (Hz)
  double durationSec = 3.0;
  double fadeSec = 0.02; // raised-cosine fade in/out to avoid clicks
  double amplitude = 0.5;
};

// Exponential (log) sine sweep, a.k.a. Farina sweep, for the measurement stimulus.
std::vector<double> generateExpSweep(const SweepSpec& spec);

// ---- Test signals (manual time alignment / centring by ear) ---------------

struct NoiseSpec {
  double fs = 48000.0;
  double durationSec = 2.0;  // one loopable block
  double fLo = 0.0;          // high-pass edge; 0 = none
  double fHi = 0.0;          // low-pass edge; 0 = none
  double amplitude = 0.3;
  unsigned seed = 1;
};

// Pink noise (-3 dB/octave), optionally band-limited.
//
// Pink is the standard signal for judging a centre image by ear: unlike a sine
// it gives the ear broadband localisation cues, and unlike white noise it is not
// so treble-heavy that it fatigues or over-weights the tweeters. Band-limiting to
// roughly 200 Hz - 4 kHz concentrates it where human localisation is sharpest.
std::vector<double> generatePinkNoise(const NoiseSpec& spec);

// ---- Levels ---------------------------------------------------------------

// RMS level of a buffer in dBFS, using the convention that a full-scale SINE
// reads -3.01 dBFS (i.e. dBFS is referenced to a full-scale square). This is the
// same convention miniDSP use for the UMIK-1 sensitivity figure.
double rmsDbfs(const std::vector<double>& x);

// Convert a measured dBFS level to dB SPL given a calibration offset.
//
// The offset cannot be derived from the mic's sensitivity alone on a phone: the
// capture gain of the USB/Android path is not known (the UMIK-1 even advertises
// its own "Gain: 18dB"), so absolute SPL needs a one-time calibration against a
// reference meter. RELATIVE levels between channels are exact without it, which
// is what level-matching drivers actually needs.
inline double splFromDbfs(double dbfs, double offsetDb) { return dbfs + offsetDb; }

// ---- Measurement ----------------------------------------------------------

// Regularized deconvolution of a recorded signal by the emitted stimulus, in the
// frequency domain:  H = (Y . conj(X)) / (|X|^2 + eps).  Returns the system impulse
// response (real). This is exact for a linear time-invariant path and immune to the
// stimulus's spectral tilt, which is why it is preferred over a raw time-reversed
// inverse filter. `epsFraction` sets the regularization floor as a fraction of the
// peak of |X|^2 (keeps division stable outside the swept band).
std::vector<double> deconvolve(const std::vector<double>& emitted,
                               const std::vector<double>& recorded,
                               double epsFraction = 1e-6);

// Index of the impulse-response peak, refined to sub-sample precision by parabolic
// interpolation around the max-magnitude sample. Used to center the analysis window;
// absolute timing is NOT used for tuning in v1 (see plan: TA is out of scope).
double irPeakIndex(const std::vector<double>& ir);

// ---- Frequency response ---------------------------------------------------

// A magnitude frequency response sampled at a set of frequencies.
struct FreqResponse {
  std::vector<double> freqHz;
  std::vector<double> magDb;
};

// Compute the (unsmoothed) magnitude response from an impulse response.
// A half-Hann window of `windowLen` samples is applied around the IR peak before the
// FFT to time-gate reflections; pass 0 to use the whole IR.
FreqResponse frequencyResponse(const std::vector<double>& ir, double fs,
                               std::size_t windowLen = 0);

// Fractional-octave smoothing (e.g. fractionOfOctave = 24 -> 1/24 octave), the kind
// used to make measured car responses readable and to drive the EQ fitter.
FreqResponse smoothFractionalOctave(const FreqResponse& fr, double fractionOfOctave);

// Resample a magnitude response onto a log-spaced frequency grid over [fMin, fMax].
FreqResponse resampleLog(const FreqResponse& fr, double fMin, double fMax,
                         std::size_t points);

// Complex-average / RMS-average several measurements taken around the listening
// position into one spatial average (all must share the same frequency grid).
FreqResponse spatialAverage(const std::vector<FreqResponse>& measurements);

}  // namespace rewcore
