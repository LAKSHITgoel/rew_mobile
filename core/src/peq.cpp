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

// Normalize the measured curve so its in-band mean sits on the target's mean; the
// hardware has a separate output-gain control, so absolute level isn't what EQ fixes.
FreqResponse levelAlign(const FreqResponse& measured, const TargetCurve& target,
                        double fMin, double fMax) {
  double diff = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = 0; i < measured.freqHz.size(); ++i) {
    const double f = measured.freqHz[i];
    if (f < fMin || f > fMax) continue;
    diff += measured.magDb[i] - target.magDb[i];
    ++cnt;
  }
  const double offset = cnt ? diff / cnt : 0.0;
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

  FreqResponse current = levelAlign(measured, target, fLo, fHi);
  result.initialErrorDb = rmsErrorDb(current, target, fLo, fHi);

  std::vector<double> centers;  // placed band centers, for anti-stacking

  for (int band = 0; band < c.maxBands; ++band) {
    double worstDev = 0.0;
    std::size_t worstIdx = 0;
    bool found = false;
    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      const double f = current.freqHz[i];
      if (f < fLo || f > fHi) continue;
      // Skip candidates too close to an already-placed band.
      bool tooClose = false;
      for (double cf : centers) {
        if (std::fabs(std::log2(f / cf)) < c.minSpacingOctave) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      const double dev = current.magDb[i] - target.magDb[i];
      if (std::fabs(dev) > std::fabs(worstDev)) {
        worstDev = dev;
        worstIdx = i;
        found = true;
      }
    }
    if (!found || std::fabs(worstDev) < 0.5) break;  // nothing worth correcting

    const double f0 = current.freqHz[worstIdx];
    const double gain = std::clamp(-worstDev, c.minGainDb, c.maxGainDb);
    const double q = estimateQ(current, target, worstIdx, fLo, fHi, c);

    result.bands.push_back({f0, gain, q});
    centers.push_back(f0);

    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      current.magDb[i] += makePeaking(f0, c.fs, gain, q).magnitudeDb(
          current.freqHz[i], c.fs);
    }
  }

  result.finalErrorDb = rmsErrorDb(current, target, fLo, fHi);
  return result;
}

}  // namespace rewcore
