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

PeqFitResult fitPeq(const FreqResponse& measured, const TargetCurve& target,
                    const PeqConstraints& c) {
  PeqFitResult result;

  FreqResponse current = levelAlign(measured, target, c.fMin, c.fMax);
  result.initialErrorDb = rmsErrorDb(current, target, c.fMin, c.fMax);

  for (int band = 0; band < c.maxBands; ++band) {
    // Find the frequency with the largest residual within the working range.
    double worstDev = 0.0;
    std::size_t worstIdx = 0;
    bool found = false;
    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      const double f = current.freqHz[i];
      if (f < c.fMin || f > c.fMax) continue;
      const double dev = current.magDb[i] - target.magDb[i];
      if (std::fabs(dev) > std::fabs(worstDev)) {
        worstDev = dev;
        worstIdx = i;
        found = true;
      }
    }
    if (!found || std::fabs(worstDev) < 0.1) break;  // nothing worth correcting

    const double f0 = current.freqHz[worstIdx];
    // A peaking band with gain = -deviation cancels the error at its center.
    double gain = std::clamp(-worstDev, c.minGainDb, c.maxGainDb);
    const double q = std::clamp(c.defaultQ, c.minQ, c.maxQ);

    const PeqBand chosen{f0, gain, q};
    result.bands.push_back(chosen);

    // Apply this band to the working curve (dB adds).
    for (std::size_t i = 0; i < current.freqHz.size(); ++i) {
      current.magDb[i] += makePeaking(f0, c.fs, gain, q).magnitudeDb(
          current.freqHz[i], c.fs);
    }
  }

  result.finalErrorDb = rmsErrorDb(current, target, c.fMin, c.fMax);
  return result;
}

}  // namespace rewcore
