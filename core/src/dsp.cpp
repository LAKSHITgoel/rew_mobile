#include "rewcore/dsp.hpp"

#include <algorithm>
#include <cmath>

#include "rewcore/fft.hpp"

namespace rewcore {

std::vector<double> generateExpSweep(const SweepSpec& s) {
  const std::size_t n = static_cast<std::size_t>(s.durationSec * s.fs);
  std::vector<double> x(n, 0.0);
  if (n == 0) return x;

  const double T = s.durationSec;
  const double L = T / std::log(s.f2 / s.f1);
  const double k = 2.0 * M_PI * s.f1 * L;

  for (std::size_t i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / s.fs;
    x[i] = s.amplitude * std::sin(k * (std::exp(t / L) - 1.0));
  }

  // Raised-cosine fades to suppress start/stop transients.
  const std::size_t fade = std::min<std::size_t>(
      static_cast<std::size_t>(s.fadeSec * s.fs), n / 2);
  for (std::size_t i = 0; i < fade; ++i) {
    const double w = 0.5 * (1.0 - std::cos(M_PI * i / fade));
    x[i] *= w;
    x[n - 1 - i] *= w;
  }
  return x;
}

std::vector<double> deconvolve(const std::vector<double>& emitted,
                               const std::vector<double>& recorded,
                               double epsFraction) {
  const std::size_t need = emitted.size() + recorded.size();
  const std::size_t N = nextPow2(need);

  std::vector<Complex> X = rfft(emitted, N);
  std::vector<Complex> Y = rfft(recorded, N);

  double maxPower = 0.0;
  for (const auto& xv : X) maxPower = std::max(maxPower, std::norm(xv));
  const double eps = epsFraction * (maxPower > 0.0 ? maxPower : 1.0);

  std::vector<Complex> H(N);
  for (std::size_t i = 0; i < N; ++i) {
    H[i] = (Y[i] * std::conj(X[i])) / (std::norm(X[i]) + eps);
  }
  return irfft(std::move(H));
}

double irPeakIndex(const std::vector<double>& ir) {
  if (ir.empty()) return 0.0;
  std::size_t peak = 0;
  double best = 0.0;
  for (std::size_t i = 0; i < ir.size(); ++i) {
    const double m = std::fabs(ir[i]);
    if (m > best) {
      best = m;
      peak = i;
    }
  }
  // Parabolic interpolation for sub-sample peak.
  if (peak > 0 && peak + 1 < ir.size()) {
    const double a = std::fabs(ir[peak - 1]);
    const double b = std::fabs(ir[peak]);
    const double c = std::fabs(ir[peak + 1]);
    const double denom = (a - 2.0 * b + c);
    if (std::fabs(denom) > 1e-12) {
      const double delta = 0.5 * (a - c) / denom;
      return static_cast<double>(peak) + delta;
    }
  }
  return static_cast<double>(peak);
}

FreqResponse frequencyResponse(const std::vector<double>& ir, double fs,
                               std::size_t windowLen) {
  std::vector<double> windowed = ir;

  if (windowLen > 0 && windowLen < ir.size()) {
    const std::size_t peak = static_cast<std::size_t>(std::lround(irPeakIndex(ir)));
    const std::size_t half = windowLen / 2;
    const std::size_t start = peak > half ? peak - half : 0;
    const std::size_t end = std::min(ir.size(), start + windowLen);
    windowed.assign(ir.size(), 0.0);
    for (std::size_t i = start; i < end; ++i) {
      // Hann window across the gate.
      const double rel = static_cast<double>(i - start) / (end - start - 1);
      const double w = 0.5 * (1.0 - std::cos(2.0 * M_PI * rel));
      windowed[i] = ir[i] * w;
    }
  }

  const std::size_t N = nextPow2(windowed.size());
  std::vector<Complex> spec = rfft(windowed, N);

  FreqResponse fr;
  const std::size_t half = N / 2;
  fr.freqHz.reserve(half);
  fr.magDb.reserve(half);
  for (std::size_t i = 1; i < half; ++i) {  // skip DC
    const double mag = std::abs(spec[i]);
    fr.freqHz.push_back(static_cast<double>(i) * fs / N);
    fr.magDb.push_back(20.0 * std::log10(mag > 1e-12 ? mag : 1e-12));
  }
  return fr;
}

FreqResponse smoothFractionalOctave(const FreqResponse& fr, double fractionOfOctave) {
  FreqResponse out;
  out.freqHz = fr.freqHz;
  out.magDb.resize(fr.magDb.size());
  if (fr.freqHz.empty()) return out;

  const double halfOct = 1.0 / (2.0 * fractionOfOctave);
  const double ratio = std::pow(2.0, halfOct);

  for (std::size_t i = 0; i < fr.freqHz.size(); ++i) {
    const double lo = fr.freqHz[i] / ratio;
    const double hi = fr.freqHz[i] * ratio;
    double acc = 0.0;
    std::size_t cnt = 0;
    for (std::size_t j = 0; j < fr.freqHz.size(); ++j) {
      if (fr.freqHz[j] >= lo && fr.freqHz[j] <= hi) {
        acc += fr.magDb[j];
        ++cnt;
      }
    }
    out.magDb[i] = cnt ? acc / cnt : fr.magDb[i];
  }
  return out;
}

static double interpDb(const FreqResponse& fr, double f) {
  // Linear interpolation in dB over log-frequency; clamps at the edges.
  const auto& xs = fr.freqHz;
  if (f <= xs.front()) return fr.magDb.front();
  if (f >= xs.back()) return fr.magDb.back();
  const auto it = std::lower_bound(xs.begin(), xs.end(), f);
  const std::size_t hi = static_cast<std::size_t>(it - xs.begin());
  const std::size_t lo = hi - 1;
  const double t = (std::log(f) - std::log(xs[lo])) /
                   (std::log(xs[hi]) - std::log(xs[lo]));
  return fr.magDb[lo] + t * (fr.magDb[hi] - fr.magDb[lo]);
}

FreqResponse resampleLog(const FreqResponse& fr, double fMin, double fMax,
                         std::size_t points) {
  FreqResponse out;
  if (points == 0 || fr.freqHz.empty()) return out;
  out.freqHz.resize(points);
  out.magDb.resize(points);
  const double logMin = std::log(fMin);
  const double logMax = std::log(fMax);
  for (std::size_t i = 0; i < points; ++i) {
    const double t = static_cast<double>(i) / (points - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    out.freqHz[i] = f;
    out.magDb[i] = interpDb(fr, f);
  }
  return out;
}

FreqResponse spatialAverage(const std::vector<FreqResponse>& measurements) {
  FreqResponse out;
  if (measurements.empty()) return out;
  out.freqHz = measurements.front().freqHz;
  out.magDb.assign(out.freqHz.size(), 0.0);

  for (std::size_t i = 0; i < out.freqHz.size(); ++i) {
    // Average in the power domain (RMS of magnitudes), which is the standard way to
    // combine spatially-distributed room/car measurements.
    double power = 0.0;
    for (const auto& m : measurements) {
      const double lin = std::pow(10.0, m.magDb[i] / 20.0);
      power += lin * lin;
    }
    power /= measurements.size();
    out.magDb[i] = 10.0 * std::log10(power > 1e-24 ? power : 1e-24);
  }
  return out;
}

}  // namespace rewcore
