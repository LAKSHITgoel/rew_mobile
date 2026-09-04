#pragma once
#include <vector>

#include "rewcore/dsp.hpp"

namespace rewcore {

enum class Slope {
  Butterworth12,   // 2nd order
  LinkwitzRiley24, // 4th order (two cascaded 2nd-order Butterworth)
  LinkwitzRiley48, // 8th order
};

// Butterworth "order" backing each slope (per branch of an LR pair).
int slopeOrder(Slope s);

// Linear magnitude of an idealized low-pass / high-pass crossover branch at
// frequency `f`, crossing at `fc`.
double lowpassMagnitude(double f, double fc, Slope s);
double highpassMagnitude(double f, double fc, Slope s);

// Result of checking how two adjacent drivers sum through their shared crossover.
struct SummationCheck {
  std::vector<double> freqHz;
  std::vector<double> summedDb;   // coherent magnitude sum of the two branches
  double maxDeviationDb = 0.0;    // worst departure from 0 dB near the crossover
};

// Predict the summed response of a low driver (low-passed at fc) and a high driver
// (high-passed at fc) over [fMin, fMax]. For Linkwitz-Riley alignments the coherent
// magnitude sum is flat, so a large deviation flags a phase/level mismatch to fix.
SummationCheck checkSummation(double fc, Slope lowSlope, Slope highSlope,
                              double fMin, double fMax, int points = 200);

// What to do about polarity at a crossover.
enum class PolarityAdvice : int {
  keep = 1,           // the drivers are summing well as wired
  invert = 2,         // inverting one measurably improves the overlap
  inconclusive = 3,   // not enough overlap, or the difference is within noise
  suspectDestructive = 4,  // summing badly, but no inverted measurement to compare
};

// Whether two drivers are working together through their crossover.
//
// Deliberately MAGNITUDE ONLY. Absolute arrival time over a wireless link is
// not stable enough to trust, so anything derived from measured phase would be
// a guess dressed up as precision. This needs none of it: measure each driver
// alone and then together, and compare what the pair actually produces in the
// overlap against what they would produce summing perfectly. Two drivers
// fighting each other come out far below that, and the answer does not depend
// on when the sweep arrived.
struct SummationAnalysis {
  bool valid = false;

  // Where both drivers genuinely contribute — outside it there is nothing to
  // say about how they combine.
  double overlapLoHz = 0.0;
  double overlapHiHz = 0.0;

  // Mean level through the overlap, in dB.
  double measuredDb = 0.0;          // the pair as wired
  double invertedDb = 0.0;          // the pair with one inverted, if measured
  double coherentDb = 0.0;          // perfectly in phase: the best possible
  double powerDb = 0.0;             // uncorrelated: coherent minus ~3 dB

  // How far the pair falls short of summing perfectly. Around 3 dB is ordinary;
  // much more means they are working against each other.
  double deficitDb = 0.0;

  // How much better inverting made it. Positive means inverted was louder
  // through the overlap.
  double invertedGainDb = 0.0;

  bool haveInverted = false;
  PolarityAdvice advice = PolarityAdvice::inconclusive;
  double confidence = 0.0;
};

// `a` and `b` are the drivers measured alone, `both` the pair as wired, and
// `bothInverted` the pair with one driver's polarity flipped (optional — pass an
// empty response if it was not measured). All four must share a frequency grid.
//
// `overlapDropDb` sets how far below its own passband a driver may be and still
// count as contributing.
SummationAnalysis analyzeSummation(const FreqResponse& a, const FreqResponse& b,
                                   const FreqResponse& both,
                                   const FreqResponse& bothInverted,
                                   double overlapDropDb = 10.0);

// Suggested crossover edges for a single measured driver, from where its response
// falls off relative to its passband.
// Why an edge was placed where it was, or why none was.
enum class CrossoverReason : int {
  measuredRolloff = 1,  // the driver measurably rolls off here
  stillStrongAtLimit = 2,  // still at full level where the sweep stopped: the
                           // driver plays past what was measured, so no
                           // crossover is suggested on this side
  notEnoughData = 3,       // too few usable points to say anything
};

// One edge of a driver's usable band.
//
// The distinction the app has to keep straight: the ACOUSTIC slope is what the
// driver does in the car, and it is what matters. The ELECTRICAL slope is what
// gets typed into the DSP. They differ by the driver's own natural roll-off,
// which is why a crossover can never be recommended from a datasheet.
struct CrossoverEdge {
  bool present = false;
  double freqHz = 0.0;  // where the response passes the -dropDb threshold

  // What the driver already does on its own, measured either side of the edge.
  double acousticSlopeDbPerOct = 0.0;
  // What to set in the DSP so the acoustic result lands near the target
  // alignment: the target minus what the driver already gives, rounded to a
  // slope a DSP actually offers.
  double electricalSlopeDbPerOct = 0.0;
  // The edge with a safety margin applied — up for a high-pass, down for a
  // low-pass — so a driver is not asked to work right at its limit.
  double recommendedHz = 0.0;

  double confidence = 0.0;  // 0..1
  CrossoverReason reason = CrossoverReason::notEnoughData;
};

struct CrossoverRecommendation {
  CrossoverEdge highPass;
  CrossoverEdge lowPass;
  double passbandDb = 0.0;  // reference passband level used

  // Kept so existing callers keep working.
  bool hasHighPass() const { return highPass.present; }
  bool hasLowPass() const { return lowPass.present; }
};

// Estimate a driver's usable band from its measured response: the passband reference
// is the median of the loudest region, and the edges are where the response drops
// `dropDb` below it. If the response is still within `dropDb` at the measured extreme,
// no crossover is suggested on that side (has*Pass == false).
// `targetAcousticDbPerOct` is the alignment being aimed at: 24 dB/octave
// (Linkwitz-Riley 4th order) is the usual choice for an active car system,
// because two LR4 halves sum flat through the overlap.
// `marginOctaves` keeps the recommendation off the driver's limit.
CrossoverRecommendation recommendCrossover(const FreqResponse& driver,
                                           double dropDb = 6.0,
                                           double targetAcousticDbPerOct = 24.0,
                                           double marginOctaves = 0.33);

}  // namespace rewcore
