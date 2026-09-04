// What the measurement looks like in TIME, rather than in frequency.
//
// A frequency response says how much energy came back at each frequency. It
// says nothing about when. In a car that omission matters more than it does in
// a room: the cabin is small and hard, every surface is close, and the thing
// that makes bass sound slow and boomy is usually not the level at 60 Hz but
// how long 60 Hz keeps going after it should have stopped. EQ can pull the
// level down; it cannot make a resonance stop ringing, which is why a car that
// measures flat can still sound wrong.
//
// Everything here comes out of the same impulse response the frequency response
// came from, so none of it costs another sweep:
//
//   * the impulse response itself — is there a clean single arrival, or is the
//     measurement full of reflections;
//   * the step response — the fastest way to see polarity, since a correctly
//     wired driver steps the right way up;
//   * the energy-time curve — where the energy is in time, on a dB scale;
//   * spectral decay ("waterfall") — the same spectrum computed at successive
//     moments, which is where a modal resonance is unmistakable: everything
//     else falls away and one frequency is still there;
//   * decay time per band — how long it takes to fall, band by band.
//
// A note on decay time in a car. RT60 as it is defined — the time for 60 dB of
// decay — cannot be measured here. A car's decay is short and its noise floor
// is high, so 60 dB below the direct sound is usually below the road and HVAC
// noise. What is measured instead is the slope over the first 20 or 30 dB and
// then extrapolated, which is standard practice (T20, T30), and this reports
// which one it managed along with how straight the decay actually was. A
// number extrapolated from a bent, noisy decay is not a measurement, and the
// caller is told so rather than left to assume.
#ifndef REWCORE_DECAY_HPP
#define REWCORE_DECAY_HPP

#include <cstddef>
#include <vector>

#include "rewcore/dsp.hpp"

namespace rewcore {

// ---------------------------------------------------------------------------
// Impulse response
// ---------------------------------------------------------------------------

struct ImpulseSpec {
  double fs = 48000.0;
  /// How much to keep before the arrival. A little is wanted: it shows the
  /// noise floor the impulse rises out of, and anything arriving early (which
  /// would mean the deconvolution has gone wrong, or a nonlinearity).
  double preMs = 5.0;
  /// How much to keep after. In a car everything of interest is within a few
  /// hundred milliseconds.
  double postMs = 300.0;
};

struct ImpulseResponse {
  bool valid = false;
  /// Normalised so the peak is 1.0 (or -1.0 if the arrival is inverted), which
  /// makes two measurements comparable without knowing either level.
  std::vector<double> samples;
  /// Time of each sample in milliseconds, relative to the arrival: negative
  /// before it, zero at it.
  std::vector<double> timeMs;
  /// Index into `samples` of the arrival.
  std::size_t peakIndex = 0;
  /// True if the arrival is negative-going — the system, as measured, is
  /// inverted. Worth knowing on its own; it is the same information the step
  /// response shows, in one bit.
  bool inverted = false;
  double fs = 48000.0;
};

ImpulseResponse computeImpulseResponse(const std::vector<double>& emitted,
                                       const std::vector<double>& recorded,
                                       const ImpulseSpec& spec);

/// Running sum of the impulse response, normalised to its own largest
/// excursion. A correctly polarised system steps up and then decays back
/// toward zero; an inverted one steps down first.
std::vector<double> stepResponse(const ImpulseResponse& ir);

/// Energy-time curve in dB, relative to the peak (so it starts at 0 and falls).
/// Computed from the analytic signal's envelope rather than from the raw
/// squared samples, so it is a smooth decay rather than a solid block of
/// oscillation with a decay hidden inside it.
std::vector<double> energyTimeCurveDb(const ImpulseResponse& ir);

// ---------------------------------------------------------------------------
// Spectral decay (waterfall)
// ---------------------------------------------------------------------------

struct WaterfallSpec {
  double fs = 48000.0;
  /// Number of time slices to compute.
  std::size_t slices = 16;
  /// How far apart the slices are in time.
  double sliceSpacingMs = 5.0;
  /// Length of the window each slice is transformed over. Longer resolves low
  /// frequencies better but blurs time; this is the usual trade and there is no
  /// setting that avoids it.
  double windowMs = 60.0;
  double fMin = 20.0;
  double fMax = 500.0;  // the interesting range in a car is the bottom
  std::size_t points = 64;
};

struct Waterfall {
  bool valid = false;
  /// One entry per slice: how long after the arrival it starts.
  std::vector<double> timeMs;
  /// Shared frequency grid.
  std::vector<double> freqHz;
  /// magDb[slice][freq], in dB relative to the peak of the first slice — so the
  /// first slice starts near 0 and everything after it falls away.
  std::vector<std::vector<double>> magDb;
};

Waterfall computeWaterfall(const ImpulseResponse& ir, const WaterfallSpec& spec);

// ---------------------------------------------------------------------------
// Decay time per band
// ---------------------------------------------------------------------------

/// Which span of the decay a band's number was actually fitted over. This is
/// not a detail: T20 from a noisy car measurement and a true RT60 are different
/// claims, and presenting them identically would overstate what was measured.
enum class DecayBasis {
  none = 0,  ///< nothing usable — the decay never cleared the noise
  t10,       ///< only 10 dB of clean decay: indicative at best
  t20,
  t30,
};

struct BandDecay {
  double centerHz = 0.0;
  /// Decay time in seconds, extrapolated to a full 60 dB from whatever span
  /// `basis` says was actually used.
  double rt60Sec = 0.0;
  /// Early decay time: the slope over the first 10 dB, extrapolated the same
  /// way. In a small space this is closer to what is heard than the late decay
  /// is, and where the two disagree strongly there is a resonance.
  double edtSec = 0.0;
  DecayBasis basis = DecayBasis::none;
  /// How straight the decay was over the fitted span, 0..1 (squared
  /// correlation of the least-squares line). A car's decay is rarely clean;
  /// below about 0.9 the number is a hint, not a measurement.
  double straightness = 0.0;
  /// Signal-to-noise available for this band, in dB — how far the decay got
  /// before it ran into the noise floor. This is what limits `basis`.
  double usableRangeDb = 0.0;
};

struct DecaySpec {
  double fs = 48000.0;
  double fMin = 32.0;
  double fMax = 8000.0;
  /// Octave bands by default. Third-octaves in a car are mostly fitting lines
  /// to noise.
  double bandsPerOctave = 1.0;
};

struct DecayResult {
  bool valid = false;
  std::vector<BandDecay> bands;
  /// Mean of the bands that produced a usable number, weighted by nothing —
  /// a plain average, quoted only as a summary.
  double averageRt60Sec = 0.0;
};

DecayResult analyzeDecay(const ImpulseResponse& ir, const DecaySpec& spec);

}  // namespace rewcore

#endif  // REWCORE_DECAY_HPP
