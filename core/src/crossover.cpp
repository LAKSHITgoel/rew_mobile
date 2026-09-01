#include "rewcore/crossover.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

namespace rewcore {

int slopeOrder(Slope s) {
  switch (s) {
    case Slope::Butterworth12:   return 1;  // 2nd-order overall / order-1 per magnitude term
    case Slope::LinkwitzRiley24: return 2;  // LR4 == two 2nd-order Butterworth
    case Slope::LinkwitzRiley48: return 4;  // LR8
  }
  return 2;
}

// For a Linkwitz-Riley crossover of order 2m the branch magnitudes are the squared
// Butterworth responses of order m:
//   |LP| = 1 / (1 + r^(2m)),  |HP| = r^(2m) / (1 + r^(2m)),   r = f/fc
// which sum coherently to exactly 1 at every frequency. Butterworth12 uses m via a
// single Butterworth term (|LP| = 1/sqrt(1+r^2)).
static double butterworthPow(double f, double fc, int m) {
  const double r = f / fc;
  return std::pow(r, 2 * m);
}

double lowpassMagnitude(double f, double fc, Slope s) {
  const int m = slopeOrder(s);
  const double r2m = butterworthPow(f, fc, m);
  if (s == Slope::Butterworth12) {
    return 1.0 / std::sqrt(1.0 + r2m);  // classic Butterworth branch
  }
  return 1.0 / (1.0 + r2m);  // Linkwitz-Riley branch
}

double highpassMagnitude(double f, double fc, Slope s) {
  const int m = slopeOrder(s);
  const double r2m = butterworthPow(f, fc, m);
  if (s == Slope::Butterworth12) {
    return std::sqrt(r2m) / std::sqrt(1.0 + r2m);
  }
  return r2m / (1.0 + r2m);
}

SummationCheck checkSummation(double fc, Slope lowSlope, Slope highSlope,
                              double fMin, double fMax, int points) {
  SummationCheck out;
  if (points < 2) points = 2;
  out.freqHz.resize(points);
  out.summedDb.resize(points);

  const double logMin = std::log(fMin);
  const double logMax = std::log(fMax);
  for (int i = 0; i < points; ++i) {
    const double t = static_cast<double>(i) / (points - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    const double lp = lowpassMagnitude(f, fc, lowSlope);
    const double hp = highpassMagnitude(f, fc, highSlope);
    const double summed = lp + hp;  // coherent (in-phase) magnitude sum
    const double db = 20.0 * std::log10(summed > 1e-12 ? summed : 1e-12);
    out.freqHz[i] = f;
    out.summedDb[i] = db;
    out.maxDeviationDb = std::max(out.maxDeviationDb, std::fabs(db));
  }
  return out;
}

CrossoverRecommendation recommendCrossover(const FreqResponse& driver,
                                           double dropDb) {
  CrossoverRecommendation rec;
  const std::size_t n = driver.magDb.size();
  if (n < 3) return rec;

  // Passband reference: median of the top 25% of levels (robust to a single peak).
  std::vector<double> sorted = driver.magDb;
  std::sort(sorted.begin(), sorted.end());
  const std::size_t lo = sorted.size() * 3 / 4;
  double acc = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = lo; i < sorted.size(); ++i) {
    acc += sorted[i];
    ++cnt;
  }
  const double ref = cnt ? acc / cnt : sorted.back();
  rec.passbandDb = ref;
  const double threshold = ref - dropDb;

  // Index of the loudest point anchors the passband.
  std::size_t peak = 0;
  for (std::size_t i = 1; i < n; ++i) {
    if (driver.magDb[i] > driver.magDb[peak]) peak = i;
  }

  // Walk down from the peak toward low frequencies; the first crossing below the
  // threshold marks the low edge (interpolated) -> high-pass point.
  for (std::size_t i = peak; i > 0; --i) {
    if (driver.magDb[i - 1] < threshold) {
      const double f0 = driver.freqHz[i - 1], f1 = driver.freqHz[i];
      const double d0 = driver.magDb[i - 1], d1 = driver.magDb[i];
      const double t = (threshold - d0) / (d1 - d0);
      rec.hasHighPass = true;
      rec.highPassHz = std::exp(std::log(f0) + t * (std::log(f1) - std::log(f0)));
      break;
    }
  }

  // Walk up from the peak toward high frequencies; the first crossing below the
  // threshold marks the high edge -> low-pass point.
  for (std::size_t i = peak; i + 1 < n; ++i) {
    if (driver.magDb[i + 1] < threshold) {
      const double f0 = driver.freqHz[i], f1 = driver.freqHz[i + 1];
      const double d0 = driver.magDb[i], d1 = driver.magDb[i + 1];
      const double t = (threshold - d0) / (d1 - d0);
      rec.hasLowPass = true;
      rec.lowPassHz = std::exp(std::log(f0) + t * (std::log(f1) - std::log(f0)));
      break;
    }
  }
  return rec;
}

}  // namespace rewcore
