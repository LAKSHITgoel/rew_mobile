#pragma once
#include <vector>

#include "rewcore/biquad.hpp"
#include "rewcore/dsp.hpp"

namespace rewcore {

// Target curve for EQ: a magnitude response the fitter tries to match. Typically flat,
// a Harman-style in-car tilt, or a user-saved preference.
using TargetCurve = FreqResponse;

// A flat target at 0 dB across the response's frequencies.
TargetCurve flatTarget(const FreqResponse& like);

// A gently tilted target (downward `slopeDbPerOctave`, negative = treble roll-off),
// anchored at `pivotHz`. A mild negative slope approximates common in-car preference.
TargetCurve tiltTarget(const FreqResponse& like, double pivotHz, double slopeDbPerOctave);

// Constraints matching what the DSP hardware can actually accept.
struct PeqConstraints {
  int maxBands = 10;
  double fs = 48000.0;
  double fMin = 20.0;      // don't place correction below this
  double fMax = 20000.0;   // ...or above this
  double minGainDb = -12.0;
  double maxGainDb = 12.0;
  double minQ = 0.5;
  double maxQ = 8.0;
  double defaultQ = 3.0;         // fallback when a band's width can't be estimated
  double minSpacingOctave = 0.15; // don't stack two bands closer than this
  double edgeGuardOctave = 0.2;   // ignore corrections within this of fMin/fMax
                                  // (the sweep's extreme edges are low-confidence)
  // Never BOOST where the driver has essentially no output: if the measured level
  // sits more than this far below the passband, a boost is trying to resurrect
  // something that isn't there — it burns amplifier headroom and can wreck drivers.
  // Cuts are always allowed. Set very large to disable the guard.
  double maxBoostBelowPassbandDb = 10.0;
  // Ignore entirely anything this far below the passband. Such regions are
  // outside the driver's range (or noise), so there is nothing to correct there
  // — and, crucially, letting them into the error metric drags the notion of
  // "flat" far below where the driver actually plays, which makes the fitter
  // attenuate the whole response instead of levelling it.
  double fitFloorBelowPassbandDb = 25.0;
  // Where in the usable band's level distribution the flat target sits, as a
  // percentile. Low values put the target under most of the response so the fit
  // comes out mostly CUTS, which is deliberate: peaks are real and cuttable,
  // whereas dips are usually cancellation nulls that boosting cannot fill — it
  // only burns headroom. The cost is that the whole response ends up quieter,
  // which you make back on the DSP's output gain.
  double targetPercentile = 0.25;
  // Boosting is only ever allowed into BROAD dips. A narrow dip is a
  // cancellation null: the cancellation removes the boost along with everything
  // else, so you burn amplifier power and headroom for no audible gain. Broad
  // dips are usually genuine response shape and do lift. Q above this is treated
  // as a null and left alone; boosts are capped separately because even a real
  // dip is not worth unlimited power.
  double maxBoostQ = 2.0;
  double maxBoostDb = 6.0;
  // The deepest CUT a single band may apply. The rail (minGainDb) is what the
  // hardware accepts; this is what is worth entering. A -12 dB band is not a
  // correction, it is a channel turned off: on a subwoofer channel it takes the
  // sub out of the system entirely, which is what happened in the car. A broad
  // excess of bass is a level problem — turn the channel down and keep the
  // headroom — so anything past this is reported as a level trim instead of
  // being dialled into one band.
  double maxCutDb = 6.0;
};

struct PeqFitResult {
  // How much deeper the fit wanted to cut than maxCutDb allowed, in dB. Non-zero
  // means the response has a broad excess that belongs on the channel's level
  // control rather than in a filter: turn that channel down by this much.
  double suggestedLevelTrimDb = 0.0;

  std::vector<PeqBand> bands;
  double initialErrorDb = 0.0;  // RMS error before EQ
  double finalErrorDb = 0.0;    // RMS error after EQ
};

// Greedy parametric-EQ auto-fit: repeatedly finds the worst-deviating region of
// (measured - target) and places a peaking band to correct it, up to maxBands.
// Returns the chosen bands (freq / gain / Q) and the error reduction. `measured`
// should already be smoothed (e.g. 1/24 octave) and on a log grid.
PeqFitResult fitPeq(const FreqResponse& measured, const TargetCurve& target,
                    const PeqConstraints& c);

// RMS deviation (dB) between a response and a target over their shared grid,
// restricted to [fMin, fMax].
double rmsErrorDb(const FreqResponse& response, const TargetCurve& target,
                  double fMin, double fMax);

}  // namespace rewcore
