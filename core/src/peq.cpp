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

PeqFitResult fitPeq(const FreqResponse& measured, const TargetCurve& target,
                    const PeqConstraints& c) {
  PeqFitResult result;

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

    if (gain > 0.0) {
      if (q > c.maxBoostQ) {
        // A narrow dip — a null. Boosting it is wasted power, so leave it and
        // stop reconsidering it, otherwise the search picks it again forever.
        rejected.push_back(f0);
        continue;
      }
      gain = std::min(gain, c.maxBoostDb);
    }

    result.bands.push_back({f0, gain, q});
    centers.push_back(f0);

    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      current.magDb[i] += makePeaking(f0, c.fs, gain, q).magnitudeDb(
          current.freqHz[i], c.fs);
    }
  }

  result.finalErrorDb =
      rmsErrorAboveFloor(current, target, fLo, fHi, fitFloorDb);
  return result;
}

}  // namespace rewcore
