// Harmonic distortion, taken from the same sweep as the frequency response.
//
// This is the quiet gift of an exponential sweep. Deconvolve one and the
// distortion products do not smear across the result the way they would with
// noise or a stepped tone — they separate out in TIME, each harmonic arriving
// as its own impulse response a fixed distance ahead of the linear one. So a
// measurement already being taken carries the distortion data for free; it only
// has to be cut out of the right places.
//
// The offset for the Nth harmonic is
//
//     dt_N = duration * ln(N) / ln(f2 / f1)
//
// which follows from the sweep's rate: an exponential sweep passes N*f exactly
// that long before it reaches f, so energy generated at N*f by a nonlinearity
// arrives that much early.
//
// In a car this is what catches a driver being asked for more than it has —
// a door speaker breaking up at 80 Hz, or a tweeter straining when the level
// goes past what it likes. Neither shows up in a magnitude response, which is
// why a flat-looking system can still sound wrong when it is turned up.
#ifndef REWCORE_DISTORTION_HPP
#define REWCORE_DISTORTION_HPP

#include <cstddef>
#include <vector>

#include "rewcore/dsp.hpp"

namespace rewcore {

struct DistortionSpec {
  double fs = 48000.0;
  double f1 = 18.0;       // sweep start
  double f2 = 22000.0;    // sweep end
  double durationSec = 5.5;
  // Harmonics to extract, from the 2nd upward. Beyond about the 5th they sit
  // so close together in time that the windows overlap and the numbers stop
  // meaning much.
  int maxHarmonic = 5;
  double fMin = 20.0;
  double fMax = 20000.0;
  std::size_t points = 96;
};

struct DistortionResult {
  bool valid = false;

  /// The linear response, on the same grid, for reference.
  FreqResponse fundamental;

  /// harmonics[0] is the 2nd, [1] the 3rd, and so on. Each is plotted against
  /// the FUNDAMENTAL frequency that produced it, not the frequency the energy
  /// came out at — that is what makes it readable next to the response.
  std::vector<FreqResponse> harmonics;

  /// Total harmonic distortion as a percentage of the fundamental, per
  /// frequency. Percent rather than dB because that is how loudspeaker
  /// distortion is quoted and argued about.
  FreqResponse thdPercent;

  /// Worst THD anywhere in the analysed band, and where.
  double worstThdPercent = 0.0;
  double worstThdHz = 0.0;
};

/// `emitted` is the sweep as generated, `recorded` what came back.
DistortionResult analyzeDistortion(const std::vector<double>& emitted,
                                   const std::vector<double>& recorded,
                                   const DistortionSpec& spec);

}  // namespace rewcore

#endif  // REWCORE_DISTORTION_HPP
