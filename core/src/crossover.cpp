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

// Least-squares slope of level against log2(frequency), in dB per octave, over
// the points between two indices — the driver's natural roll-off. Also returns
// how well a straight line actually described it (R^2), which is the honest
// measure of whether "slope" means anything here: a clean roll-off fits a line,
// while a lumpy cancellation-riddled one does not.
static void slopeOverRange(const FreqResponse& r, std::size_t a, std::size_t b,
                           double* slopeDbPerOct, double* r2) {
  *slopeDbPerOct = 0.0;
  *r2 = 0.0;
  if (b <= a || b >= r.freqHz.size()) return;
  const std::size_t n = b - a + 1;
  if (n < 3) return;

  double sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (std::size_t i = a; i <= b; ++i) {
    const double x = std::log2(r.freqHz[i]);
    const double y = r.magDb[i];
    sx += x; sy += y; sxx += x * x; sxy += x * y;
  }
  const double dn = static_cast<double>(n);
  const double denom = dn * sxx - sx * sx;
  if (std::fabs(denom) < 1e-12) return;
  const double slope = (dn * sxy - sx * sy) / denom;
  const double intercept = (sy - slope * sx) / dn;

  double ssTot = 0, ssRes = 0;
  const double meanY = sy / dn;
  for (std::size_t i = a; i <= b; ++i) {
    const double x = std::log2(r.freqHz[i]);
    const double pred = slope * x + intercept;
    ssRes += (r.magDb[i] - pred) * (r.magDb[i] - pred);
    ssTot += (r.magDb[i] - meanY) * (r.magDb[i] - meanY);
  }
  *slopeDbPerOct = slope;
  *r2 = ssTot > 1e-12 ? std::clamp(1.0 - ssRes / ssTot, 0.0, 1.0) : 0.0;
}

// DSP filters come in 6 dB steps; recommending 17 dB/octave helps nobody.
static double roundToAvailableSlope(double dbPerOct) {
  const double steps[] = {0.0, 6.0, 12.0, 18.0, 24.0, 36.0, 48.0};
  double best = 0.0, bestErr = 1e18;
  for (double s : steps) {
    const double e = std::fabs(s - dbPerOct);
    if (e < bestErr) { bestErr = e; best = s; }
  }
  return best;
}

CrossoverRecommendation recommendCrossover(const FreqResponse& driver,
                                           double dropDb,
                                           double targetAcousticDbPerOct,
                                           double marginOctaves) {
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

  // Fills in one edge once its crossing index has been found.
  auto describe = [&](CrossoverEdge& edge, std::size_t idx, bool highPass) {
    // Measure the natural roll-off over about an octave outside the edge.
    const double f = driver.freqHz[idx];
    std::size_t a = idx, b = idx;
    if (highPass) {
      const double lowF = f / 2.0;
      a = 0;
      for (std::size_t i = 0; i < idx; ++i) {
        if (driver.freqHz[i] >= lowF) { a = i; break; }
      }
      b = idx;
    } else {
      a = idx;
      const double highF = f * 2.0;
      b = n - 1;
      for (std::size_t i = idx; i < n; ++i) {
        if (driver.freqHz[i] >= highF) { b = i; break; }
      }
    }
    double slope = 0.0, r2 = 0.0;
    slopeOverRange(driver, a, b, &slope, &r2);
    // A high-pass edge falls as frequency drops, so its fitted slope is
    // positive going up; report roll-off magnitude either way.
    edge.acousticSlopeDbPerOct = std::fabs(slope);

    const double remaining =
        std::max(0.0, targetAcousticDbPerOct - edge.acousticSlopeDbPerOct);
    edge.electricalSlopeDbPerOct = roundToAvailableSlope(remaining);

    // Keep the driver off its limit: high-pass a little higher, low-pass a
    // little lower than the raw -dropDb point.
    edge.recommendedHz = highPass ? f * std::pow(2.0, marginOctaves)
                                  : f / std::pow(2.0, marginOctaves);

    // Confidence: how straight the roll-off was, and how far the edge sits
    // from the end of what was actually measured. An edge landing on the last
    // point of the sweep is a guess about a region nobody looked at.
    const double octFromEnd =
        highPass ? std::log2(f / driver.freqHz.front())
                 : std::log2(driver.freqHz.back() / f);
    const double room = std::clamp(octFromEnd / 0.5, 0.0, 1.0);
    edge.confidence = std::clamp(std::sqrt(std::max(r2, 0.0)) * 0.6 + room * 0.4,
                                 0.0, 1.0);
    edge.reason = CrossoverReason::measuredRolloff;
    edge.present = true;
  };

  // Walk down from the peak toward low frequencies; the first crossing below the
  // threshold marks the low edge (interpolated) -> high-pass point.
  bool foundHigh = false;
  for (std::size_t i = peak; i > 0; --i) {
    if (driver.magDb[i - 1] < threshold) {
      const double f0 = driver.freqHz[i - 1], f1 = driver.freqHz[i];
      const double d0 = driver.magDb[i - 1], d1 = driver.magDb[i];
      const double t = (threshold - d0) / (d1 - d0);
      rec.highPass.freqHz =
          std::exp(std::log(f0) + t * (std::log(f1) - std::log(f0)));
      describe(rec.highPass, i - 1, true);
      rec.highPass.freqHz =
          std::exp(std::log(f0) + t * (std::log(f1) - std::log(f0)));
      rec.highPass.recommendedHz =
          rec.highPass.freqHz * std::pow(2.0, marginOctaves);
      foundHigh = true;
      break;
    }
  }
  if (!foundHigh) {
    rec.highPass.reason = CrossoverReason::stillStrongAtLimit;
  }

  // Walk up from the peak toward high frequencies; the first crossing below the
  // threshold marks the high edge -> low-pass point.
  bool foundLow = false;
  for (std::size_t i = peak; i + 1 < n; ++i) {
    if (driver.magDb[i + 1] < threshold) {
      const double f0 = driver.freqHz[i], f1 = driver.freqHz[i + 1];
      const double d0 = driver.magDb[i], d1 = driver.magDb[i + 1];
      const double t = (threshold - d0) / (d1 - d0);
      rec.lowPass.freqHz =
          std::exp(std::log(f0) + t * (std::log(f1) - std::log(f0)));
      describe(rec.lowPass, i + 1, false);
      rec.lowPass.freqHz =
          std::exp(std::log(f0) + t * (std::log(f1) - std::log(f0)));
      rec.lowPass.recommendedHz =
          rec.lowPass.freqHz / std::pow(2.0, marginOctaves);
      foundLow = true;
      break;
    }
  }
  if (!foundLow) {
    rec.lowPass.reason = CrossoverReason::stillStrongAtLimit;
  }
  return rec;
}

}  // namespace rewcore
