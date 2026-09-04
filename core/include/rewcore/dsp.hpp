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

// What a capture looks like before anyone tries to interpret it.
//
// A bad measurement must never reach a recommendation, and the failures that
// matter in a car are not subtle: the input clipped, nothing arrived at all, or
// the recording is mostly silence because the wrong channel was playing. Each
// is cheap to detect and impossible to spot on a smoothed magnitude plot after
// the fact.
struct CaptureQuality {
  double peak = 0.0;          // absolute peak, 0..1+
  double rmsDbfs = -240.0;
  double clippedFraction = 0.0;  // samples at or beyond full scale
  // Fraction of the capture whose short-term level sits near the noise floor.
  // A sweep should be audible for most of its length; a mostly-dead recording
  // means the channel under test was not the one playing.
  double silentFraction = 0.0;
  bool clipped = false;
  bool tooQuiet = false;
  bool mostlySilent = false;
  bool usable = false;
};

CaptureQuality assessCapture(const std::vector<double>& x, double fs);


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

// A frequency response sampled at a set of frequencies.
//
// `phaseDeg` is optional (empty where phase is not meaningful, e.g. after a
// power average of spatially separated captures, which destroys phase). When
// present it is UNWRAPPED, so a pure delay shows as a straight downward ramp
// rather than sawtoothing between +-180.
struct FreqResponse {
  std::vector<double> freqHz;
  std::vector<double> magDb;
  std::vector<double> phaseDeg;

  bool hasPhase() const { return phaseDeg.size() == freqHz.size(); }
};

// Remove the +-180 wraps from a phase curve in place, so it can be interpolated
// and read as a continuous quantity.
void unwrapPhaseDeg(std::vector<double>& phaseDeg);

// Compute the (unsmoothed) magnitude response from an impulse response.
// A half-Hann window of `windowLen` samples is applied around the IR peak before the
// FFT to time-gate reflections; pass 0 to use the whole IR.
// When `timeReference` is true the impulse response is rotated so its peak sits
// at t=0 before the transform. That removes the bulk propagation delay, which is
// essential for phase to be readable: over Bluetooth the path delay is tens of
// milliseconds, which alone is thousands of degrees of phase at 1 kHz and swamps
// the shape you actually care about. Magnitude is unaffected. Leave it false to
// measure the delay itself.
FreqResponse frequencyResponse(const std::vector<double>& ir, double fs,
                               std::size_t windowLen = 0,
                               bool timeReference = false);

// Fractional-octave smoothing (e.g. fractionOfOctave = 24 -> 1/24 octave), the kind
// used to make measured car responses readable and to drive the EQ fitter.
FreqResponse smoothFractionalOctave(const FreqResponse& fr, double fractionOfOctave);

// Resample a magnitude response onto a log-spaced frequency grid over [fMin, fMax].
FreqResponse resampleLog(const FreqResponse& fr, double fMin, double fMax,
                         std::size_t points);

// ---- Level check ----------------------------------------------------------

// Is the measurement being made at a sensible volume?
//
// This is the step that was missing, and it is the one that decides whether
// everything downstream is worth anything. Too quiet and the sweep never gets
// clear of the car's own noise, so the top of the response is a picture of road
// and HVAC noise and the EQ fitter cheerfully corrects it. Too loud and the
// input clips, or the drivers start distorting, and the response is of a system
// being driven past where it works. Both produce a curve that looks entirely
// plausible.
//
// Deliberately separate from assessCapture: that one asks "is this recording
// broken", which is a yes/no about a measurement already taken. This asks "is
// the volume right", which is advice given BEFORE measuring, and needs the
// noise floor to answer at all.
enum class LevelVerdict {
  noSignal = 0,   ///< nothing arrived — wrong channel, or nothing playing
  clipping,       ///< the input is being overloaded
  tooLoud,        ///< not clipping yet, but no headroom left
  tooQuiet,       ///< clear of the noise nowhere useful
  marginal,       ///< usable, but the top of the band is noise-limited
  good,
};

struct LevelCheck {
  LevelVerdict verdict = LevelVerdict::noSignal;
  double peakDbfs = -240.0;
  double rmsDbfs = -240.0;
  /// Median signal-to-noise across the band, in dB.
  double medianSnrDb = 0.0;
  /// Highest frequency at which the sweep still clears `minSnrDb`. This is the
  /// number that matters in a car: a link running SBC, or a sweep played too
  /// quietly, both show up as a response that simply stops partway up.
  double usableToHz = 0.0;
  /// How much louder (positive) or quieter (negative) to play it, in dB. Zero
  /// when the level is already right. This is a suggestion, not a measurement:
  /// the car's volume control is not calibrated, so it is a direction and a
  /// rough size.
  double suggestedChangeDb = 0.0;
};

// `recorded` is a captured sweep and `noise` the same capture with nothing
// played; `signal` and `noiseFloor` are their analysed responses, on a shared
// frequency grid. minSnrDb is the margin a point must clear to count as
// measured rather than guessed at.
LevelCheck assessLevel(const std::vector<double>& recorded,
                       const FreqResponse& signal,
                       const FreqResponse& noiseFloor, double fs,
                       double minSnrDb = 10.0);

// Complex-average / RMS-average several measurements taken around the listening
// position into one spatial average (all must share the same frequency grid).
FreqResponse spatialAverage(const std::vector<FreqResponse>& measurements);

// Per-point standard deviation across repeated captures, in dB. This is the
// measurement's repeatability: a feature that holds still across captures is a
// property of the car, while one that moves is the microphone position, a
// passing car, or the wireless link misbehaving. It is the strongest input to
// whether a deviation is worth correcting, so it is computed here rather than
// thrown away by averaging.
FreqResponse responseSpread(const std::vector<FreqResponse>& measurements);

}  // namespace rewcore
