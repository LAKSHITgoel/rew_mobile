#include "rewcore/peq.hpp"

#include <algorithm>
#include <cmath>

namespace rewcore {

TargetCurve flatTarget(const FreqResponse& like) {
  TargetCurve t;
  t.freqHz = like.freqHz;
  t.magDb.assign(like.freqHz.size(), 0.0);
  return t;
}

TargetCurve makeTarget(const FreqResponse& like, const TargetShape& shape) {
  TargetCurve t;
  t.freqHz = like.freqHz;
  t.magDb.assign(like.freqHz.size(), 0.0);
  for (std::size_t i = 0; i < like.freqHz.size(); ++i) {
    const double f = like.freqHz[i];
    if (f <= 0.0) continue;
    double db = 0.0;

    // Bass shelf: 1 well below the corner, 0 well above, easing across it.
    // tanh rather than a hard step so the fitter is not handed a corner to
    // chase with a filter.
    if (shape.bassShelfDb != 0.0) {
      const double width = std::max(0.1, shape.bassShelfWidthOct);
      const double x = std::log2(f / shape.bassShelfHz) / (width * 0.5);
      db += shape.bassShelfDb * 0.5 * (1.0 - std::tanh(x));
    }

    // Tilt, above the pivot only.
    if (shape.tiltDbPerOctave != 0.0 && f > shape.tiltPivotHz) {
      db += shape.tiltDbPerOctave * std::log2(f / shape.tiltPivotHz);
    }
    t.magDb[i] = db;
  }
  return t;
}

TargetCurve tiltTarget(const FreqResponse& like, double pivotHz,
                       double slopeDbPerOctave) {
  TargetCurve t;
  t.freqHz = like.freqHz;
  t.magDb.resize(like.freqHz.size());
  for (std::size_t i = 0; i < like.freqHz.size(); ++i) {
    const double octaves = std::log2(like.freqHz[i] / pivotHz);
    t.magDb[i] = slopeDbPerOctave * octaves;
  }
  return t;
}

// RMS error counting only points at or above `floorDb` — see
// PeqConstraints::fitFloorBelowPassbandDb.
static double rmsErrorAboveFloor(const FreqResponse& response,
                                 const TargetCurve& target, double fMin,
                                 double fMax, double floorDb) {
  double acc = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = 0; i < response.freqHz.size(); ++i) {
    const double f = response.freqHz[i];
    if (f < fMin || f > fMax) continue;
    if (response.magDb[i] < floorDb) continue;
    const double e = response.magDb[i] - target.magDb[i];
    acc += e * e;
    ++cnt;
  }
  return cnt ? std::sqrt(acc / cnt) : 0.0;
}

double rmsErrorDb(const FreqResponse& response, const TargetCurve& target,
                  double fMin, double fMax) {
  double acc = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = 0; i < response.freqHz.size(); ++i) {
    const double f = response.freqHz[i];
    if (f < fMin || f > fMax) continue;
    const double e = response.magDb[i] - target.magDb[i];
    acc += e * e;
    ++cnt;
  }
  return cnt ? std::sqrt(acc / cnt) : 0.0;
}

namespace {

// Passband reference: the median of the loudest quarter of the in-band response.
// Robust to a single narrow peak, and to the deep nulls we must not try to fill.
double passbandReferenceDb(const FreqResponse& fr, double fLo, double fHi) {
  std::vector<double> inBand;
  for (std::size_t i = 0; i < fr.freqHz.size(); ++i) {
    if (fr.freqHz[i] >= fLo && fr.freqHz[i] <= fHi) inBand.push_back(fr.magDb[i]);
  }
  if (inBand.empty()) return 0.0;
  std::sort(inBand.begin(), inBand.end());
  const std::size_t start = inBand.size() * 3 / 4;
  double acc = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = start; i < inBand.size(); ++i) {
    acc += inBand[i];
    ++cnt;
  }
  return cnt ? acc / cnt : inBand.back();
}

}  // namespace

namespace {

// Normalize the measured curve so its PASSBAND sits on the target; the hardware
// has a separate output-gain control, so absolute level isn't what EQ fixes.
//
// Anchoring to the passband rather than the whole-band mean matters: a real car
// measurement contains regions tens of dB down (below the driver's range, or
// just noise). Averaging those in drags the target far below where the driver
// actually plays, and the fitter then "flattens" by cutting everything down to
// meet it — attenuating rather than levelling.
FreqResponse levelAlign(const FreqResponse& measured, const TargetCurve& target,
                        double fMin, double fMax, double percentile) {
  double targetSum = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = 0; i < measured.freqHz.size(); ++i) {
    const double f = measured.freqHz[i];
    if (f < fMin || f > fMax) continue;
    targetSum += target.magDb[i];
    ++cnt;
  }
  const double targetRef = cnt ? targetSum / cnt : 0.0;

  // Anchor to the MEDIAN of the usable band, not its loudest quarter. The top
  // quartile sits above almost every point, so aligning to it leaves the whole
  // response looking too quiet and the fitter answers with boosts; the median
  // centres it, so corrections come out balanced and the overall level barely
  // moves. (The dead region is excluded first, or it drags the median down.)
  const double passband = passbandReferenceDb(measured, fMin, fMax);
  std::vector<double> usable;
  for (std::size_t i = 0; i < measured.freqHz.size(); ++i) {
    const double f = measured.freqHz[i];
    if (f < fMin || f > fMax) continue;
    if (measured.magDb[i] < passband - 25.0) continue;
    usable.push_back(measured.magDb[i]);
  }
  double centre = passband;
  if (!usable.empty()) {
    std::sort(usable.begin(), usable.end());
    const std::size_t idx = std::min(
        usable.size() - 1,
        static_cast<std::size_t>(percentile * (usable.size() - 1)));
    centre = usable[idx];
  }
  const double offset = centre - targetRef;
  FreqResponse out = measured;
  for (double& m : out.magDb) m -= offset;
  return out;
}

}  // namespace

namespace {

// Estimate the Q of the deviation around index `i0` by walking outward until the
// residual falls to half its peak magnitude (or changes sign / hits the range edge),
// giving the bandwidth in octaves. Q is derived from that bandwidth.
double estimateQ(const FreqResponse& r, const TargetCurve& t, std::size_t i0,
                 double fLo, double fHi, const PeqConstraints& c) {
  const double peak = r.magDb[i0] - t.magDb[i0];
  const double halfMag = std::fabs(peak) * 0.5;
  const double sign = peak >= 0 ? 1.0 : -1.0;

  auto beyondHalf = [&](std::size_t i) {
    const double dev = r.magDb[i] - t.magDb[i];
    return (sign * dev) < halfMag;  // dropped below half, or crossed sign
  };

  std::size_t lo = i0, hi = i0;
  while (lo > 0 && r.freqHz[lo - 1] >= fLo && !beyondHalf(lo - 1)) --lo;
  while (hi + 1 < r.freqHz.size() && r.freqHz[hi + 1] <= fHi && !beyondHalf(hi + 1))
    ++hi;

  const double fA = r.freqHz[lo];
  const double fB = r.freqHz[hi];
  if (fA <= 0 || fB <= fA) return std::clamp(c.defaultQ, c.minQ, c.maxQ);

  const double bwOct = std::log2(fB / fA);
  if (bwOct < 1e-3) return c.maxQ;
  const double twoN = std::pow(2.0, bwOct);
  const double q = std::sqrt(twoN) / (twoN - 1.0);  // Q <-> bandwidth (octaves)
  return std::clamp(q, c.minQ, c.maxQ);
}

}  // namespace

// Confidence that a deviation is a real, correctable property of the car.
//
// Deliberately explicit rather than a tuned black box: each term is a judgement
// an experienced tuner makes by eye, written down so it can be argued with.
//   * width   — broad features behave minimum-phase and respond to EQ; narrow
//               ones are usually interference that EQ cannot fix.
//   * depth   — a 1 dB wobble is not worth a filter even if it is real.
//   * spread  — did it hold still across repeated captures? Strongest signal
//               there is, and only available when captures were repeated.
//   * edges   — the sweep's extremes are the least trustworthy part.
static double bandConfidence(double q, double devDb, double spreadDb,
                             bool haveSpread, double f, double fLo, double fHi) {
  // Broad (low Q) is good: 1.0 at Q<=1, falling away to 0.2 by Q=8.
  const double width = std::clamp(1.0 - (q - 1.0) / 7.0 * 0.8, 0.2, 1.0);
  // 0.3 at 1 dB, ~1.0 by 6 dB.
  const double depth = std::clamp(std::fabs(devDb) / 6.0, 0.3, 1.0);
  // Repeatable to within 1 dB is excellent; 3 dB is the limit of usefulness.
  const double repeat =
      haveSpread ? std::clamp(1.0 - (spreadDb - 1.0) / 2.0, 0.15, 1.0) : 0.7;
  // Fade out within a third of an octave of either analysed edge.
  const double octFromLo = std::log2(f / fLo);
  const double octFromHi = std::log2(fHi / f);
  const double edge =
      std::clamp(std::min(octFromLo, octFromHi) / 0.33, 0.3, 1.0);

  // Weighted geometric mean, NOT a product. Multiplying four independent 0..1
  // terms collapses: a merely-average score on each gives 0.2*0.5*0.5*1 = 5%,
  // and on a real car measurement every band came back "low confidence", which
  // makes the score useless as a way to tell recommendations apart. A geometric
  // mean keeps the same ordering while spanning a usable range, and lets one
  // weak term pull the score down without annihilating it.
  //
  // Repeatability carries the most weight because it is the only term measured
  // rather than inferred; the edge term is a mild correction, not a verdict.
  constexpr double wRepeat = 0.40;
  constexpr double wWidth = 0.30;
  constexpr double wDepth = 0.20;
  constexpr double wEdge = 0.10;
  const double logScore = wRepeat * std::log(repeat) + wWidth * std::log(width) +
                          wDepth * std::log(depth) + wEdge * std::log(edge);
  return std::clamp(std::exp(logScore), 0.0, 1.0);
}

PeqFitResult fitPeq(const FreqResponse& measured, const TargetCurve& target,
                    const PeqConstraints& c,
                    const std::vector<double>& spreadDb) {
  PeqFitResult result;
  const bool haveSpread = spreadDb.size() == measured.magDb.size();

  // Trust only the interior of the requested range; the sweep's extreme edges have
  // low energy and their measured values are unreliable, so don't correct there.
  const double guard = std::pow(2.0, c.edgeGuardOctave);
  const double fLo = c.fMin * guard;
  const double fHi = c.fMax / guard;

  FreqResponse current =
      levelAlign(measured, target, fLo, fHi, c.targetPercentile);

  // Where the driver actually produces output. Below the boost floor we may cut
  // but never boost; below the fit floor we ignore the region completely,
  // because trying to "correct" a dead band is what turns EQ into attenuation.
  const double passbandDb = passbandReferenceDb(current, fLo, fHi);
  const double boostFloorDb = passbandDb - c.maxBoostBelowPassbandDb;
  const double fitFloorDb = passbandDb - c.fitFloorBelowPassbandDb;

  result.initialErrorDb =
      rmsErrorAboveFloor(current, target, fLo, fHi, fitFloorDb);

  // Report the biggest deviations we will refuse to touch, so the app can say
  // what it saw and why it left it alone rather than silently omitting it.
  if (haveSpread) {
    double worstUnstable = 0.0;
    double worstUnstableF = 0.0;
    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      const double f = current.freqHz[i];
      if (f < fLo || f > fHi) continue;
      if (current.magDb[i] < fitFloorDb) continue;
      if (spreadDb[i] <= c.maxSpreadDb) continue;
      const double dev = std::fabs(current.magDb[i] - target.magDb[i]);
      if (dev > worstUnstable) {
        worstUnstable = dev;
        worstUnstableF = f;
      }
    }
    if (worstUnstable > 1.0) {
      result.declined.push_back(
          {PeqReason::declinedUnrepeatable, 0.0, worstUnstableF});
    }
  }

  std::vector<double> centers;   // placed band centers, for anti-stacking
  std::vector<double> rejected;  // nulls we decided not to boost

  for (int band = 0; band < c.maxBands; ++band) {
    double worstDev = 0.0;
    std::size_t worstIdx = 0;
    bool found = false;
    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      const double f = current.freqHz[i];
      if (f < fLo || f > fHi) continue;
      // Nothing to fix where the driver has essentially no output.
      if (current.magDb[i] < fitFloorDb) continue;
      // Skip candidates too close to an already-placed band.
      bool tooClose = false;
      for (double cf : rejected) {
        if (std::fabs(std::log2(f / cf)) < c.minSpacingOctave) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;
      for (double cf : centers) {
        if (std::fabs(std::log2(f / cf)) < c.minSpacingOctave) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      const double dev = current.magDb[i] - target.magDb[i];
      // dev < 0 means we'd be boosting here; refuse if there is nothing to boost.
      if (dev < 0.0 && current.magDb[i] < boostFloorDb) continue;
      // A feature that moved between captures is not a property of the car.
      if (haveSpread && spreadDb[i] > c.maxSpreadDb) continue;
      if (std::fabs(dev) > std::fabs(worstDev)) {
        worstDev = dev;
        worstIdx = i;
        found = true;
      }
    }
    if (!found || std::fabs(worstDev) < 0.5) break;  // nothing worth correcting

    const double f0 = current.freqHz[worstIdx];
    double gain = std::clamp(-worstDev, c.minGainDb, c.maxGainDb);
    const double q = estimateQ(current, target, worstIdx, fLo, fHi, c);

    const double spreadHere = haveSpread ? spreadDb[worstIdx] : 0.0;
    const double conf =
        bandConfidence(q, worstDev, spreadHere, haveSpread, f0, fLo, fHi);
    PeqReason reason =
        q > 3.0 ? PeqReason::narrowExcess : PeqReason::broadExcess;

    if (gain > 0.0) {
      if (q > c.maxBoostQ) {
        // A narrow dip — a null. Boosting it is wasted power, so leave it and
        // stop reconsidering it, otherwise the search picks it again forever.
        rejected.push_back(f0);
        result.declined.push_back(
            {PeqReason::declinedNarrowNull, conf, f0});
        continue;
      }
      gain = std::min(gain, c.maxBoostDb);
      reason = PeqReason::broadDeficit;
    } else if (gain < -c.maxCutDb) {
      // Deeper than a filter should go. Report the remainder as a level trim
      // rather than dialling in a band that mutes the channel.
      result.suggestedLevelTrimDb =
          std::max(result.suggestedLevelTrimDb, -gain - c.maxCutDb);
      gain = -c.maxCutDb;
      reason = PeqReason::cutLimited;
    }

    // Verify before keeping it. A filter that does not reduce the error is not
    // a correction, and on a real measurement the fitter was capable of handing
    // back EQ that made the response measurably worse (5.1 -> 5.3 dB RMS on a
    // rolled-off driver, where it was "lifting" a band that is simply not
    // there). Never ship a band that loses.
    const double before =
        rmsErrorAboveFloor(current, target, fLo, fHi, fitFloorDb);
    FreqResponse candidate = current;
    const Biquad filter = makePeaking(f0, c.fs, gain, q);
    for (std::size_t i = 0; i < candidate.freqHz.size(); ++i) {
      candidate.magDb[i] += filter.magnitudeDb(candidate.freqHz[i], c.fs);
    }
    const double after =
        rmsErrorAboveFloor(candidate, target, fLo, fHi, fitFloorDb);
    if (after >= before - 1e-9) {
      rejected.push_back(f0);
      result.declined.push_back({PeqReason::declinedNoImprovement, conf, f0});
      continue;
    }

    result.bands.push_back({f0, gain, q});
    result.rationale.push_back({reason, conf, f0});
    centers.push_back(f0);
    current = candidate;
  }

  result.finalErrorDb =
      rmsErrorAboveFloor(current, target, fLo, fHi, fitFloorDb);
  return result;
}

}  // namespace rewcore
