#pragma once
#include <vector>

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

}  // namespace rewcore
