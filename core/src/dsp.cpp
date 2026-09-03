#include "rewcore/dsp.hpp"

#include <algorithm>
#include <cmath>

#include "rewcore/biquad.hpp"
#include "rewcore/fft.hpp"

#include <random>

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

double rmsDbfs(const std::vector<double>& x) {
  if (x.empty()) return -240.0;
  double acc = 0.0;
  for (double v : x) acc += v * v;
  const double rms = std::sqrt(acc / static_cast<double>(x.size()));
  // Plain 20*log10(rms) already gives the convention we want: a full-scale sine
  // has rms 0.7071, so it reads -3.01 dBFS (not 0), which is how miniDSP quote
  // the UMIK-1 sensitivity figure.
  return 20.0 * std::log10(rms > 1e-12 ? rms : 1e-12);
}

std::vector<double> generatePinkNoise(const NoiseSpec& s) {
  const std::size_t n = static_cast<std::size_t>(s.durationSec * s.fs);
  std::vector<double> x(n, 0.0);
  if (n == 0) return x;

  // Deterministic so a given band always sounds identical between runs.
  std::mt19937 rng(s.seed);
  std::uniform_real_distribution<double> uni(-1.0, 1.0);

  // Paul Kellet's economy pink filter: a bank of one-pole sections whose sum
  // approximates a -3 dB/octave slope across the audio band.
  double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
  for (std::size_t i = 0; i < n; ++i) {
    const double w = uni(rng);
    b0 = 0.99886 * b0 + w * 0.0555179;
    b1 = 0.99332 * b1 + w * 0.0750759;
    b2 = 0.96900 * b2 + w * 0.1538520;
    b3 = 0.86650 * b3 + w * 0.3104856;
    b4 = 0.55000 * b4 + w * 0.5329522;
    b5 = -0.7616 * b5 - w * 0.0168980;
    x[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362;
    b6 = w * 0.115926;
  }

  // Optional band limiting (two cascaded sections a side for a usable slope).
  if (s.fLo > 0.0 && s.fLo < s.fs / 2) {
    const Biquad hp = makeHighPass(s.fLo, s.fs);
    for (int pass = 0; pass < 2; ++pass) {
      double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
      for (std::size_t i = 0; i < n; ++i) {
        const double o = hp.b0 * x[i] + hp.b1 * x1 + hp.b2 * x2 - hp.a1 * y1 - hp.a2 * y2;
        x2 = x1; x1 = x[i]; y2 = y1; y1 = o; x[i] = o;
      }
    }
  }
  if (s.fHi > 0.0 && s.fHi < s.fs / 2) {
    const Biquad lp = makeLowPass(s.fHi, s.fs);
    for (int pass = 0; pass < 2; ++pass) {
      double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
      for (std::size_t i = 0; i < n; ++i) {
        const double o = lp.b0 * x[i] + lp.b1 * x1 + lp.b2 * x2 - lp.a1 * y1 - lp.a2 * y2;
        x2 = x1; x1 = x[i]; y2 = y1; y1 = o; x[i] = o;
      }
    }
  }

  // Normalise to the requested amplitude (peak), so level is predictable.
  double peak = 0.0;
  for (double v : x) peak = std::max(peak, std::fabs(v));
  if (peak > 0.0) {
    const double g = s.amplitude / peak;
    for (double& v : x) v *= g;
  }

  // Short fades so a looped block does not click at the wrap.
  const std::size_t fade = std::min<std::size_t>(static_cast<std::size_t>(0.005 * s.fs), n / 2);
  for (std::size_t i = 0; i < fade; ++i) {
    const double w = static_cast<double>(i) / fade;
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

void unwrapPhaseDeg(std::vector<double>& p) {
  for (std::size_t i = 1; i < p.size(); ++i) {
    double d = p[i] - p[i - 1];
    while (d > 180.0) {
      p[i] -= 360.0;
      d = p[i] - p[i - 1];
    }
    while (d < -180.0) {
      p[i] += 360.0;
      d = p[i] - p[i - 1];
    }
  }
}

FreqResponse frequencyResponse(const std::vector<double>& ir, double fs,
                               std::size_t windowLen, bool timeReference) {
  std::vector<double> windowed = ir;

  if (timeReference && !ir.empty()) {
    // Rotate so the arrival sits at t=0; the leftover phase is then the
    // system's own, not the flight time from the speaker to the mic.
    const std::size_t peak =
        static_cast<std::size_t>(std::lround(irPeakIndex(ir))) % ir.size();
    if (peak != 0) {
      std::vector<double> rotated(ir.size());
      for (std::size_t i = 0; i < ir.size(); ++i) {
        rotated[i] = ir[(i + peak) % ir.size()];
      }
      windowed = rotated;
    }
  }

  if (windowLen > 0 && windowLen < windowed.size()) {
    const std::vector<double> src = windowed;
    const std::size_t peak =
        static_cast<std::size_t>(std::lround(irPeakIndex(src)));
    const std::size_t half = windowLen / 2;
    const std::size_t start = peak > half ? peak - half : 0;
    const std::size_t end = std::min(src.size(), start + windowLen);
    windowed.assign(src.size(), 0.0);
    for (std::size_t i = start; i < end; ++i) {
      // Hann window across the gate.
      const double rel = static_cast<double>(i - start) / (end - start - 1);
      const double w = 0.5 * (1.0 - std::cos(2.0 * M_PI * rel));
      windowed[i] = src[i] * w;
    }
  }

  const std::size_t N = nextPow2(windowed.size());
  std::vector<Complex> spec = rfft(windowed, N);

  FreqResponse fr;
  const std::size_t half = N / 2;
  fr.freqHz.reserve(half);
  fr.magDb.reserve(half);
  fr.phaseDeg.reserve(half);
  for (std::size_t i = 1; i < half; ++i) {  // skip DC
    const double mag = std::abs(spec[i]);
    fr.freqHz.push_back(static_cast<double>(i) * fs / N);
    fr.magDb.push_back(20.0 * std::log10(mag > 1e-12 ? mag : 1e-12));
    fr.phaseDeg.push_back(std::arg(spec[i]) * 180.0 / M_PI);
  }
  unwrapPhaseDeg(fr.phaseDeg);
  return fr;
}

FreqResponse smoothFractionalOctave(const FreqResponse& fr, double fractionOfOctave) {
  FreqResponse out;
  out.freqHz = fr.freqHz;
  out.magDb.resize(fr.magDb.size());
  if (fr.freqHz.empty()) return out;

  const double halfOct = 1.0 / (2.0 * fractionOfOctave);
  const double ratio = std::pow(2.0, halfOct);

  // freqHz is ascending and the window bounds (f/ratio, f*ratio) grow monotonically
  // with i, so the window can slide with two pointers and a running sum: O(n) instead
  // of the O(n^2) scan this used to do. That matters — a 3 s sweep yields ~260k bins,
  // where the quadratic version pegged a phone's CPU for minutes.
  const std::size_t n = fr.freqHz.size();
  std::size_t lo = 0, hi = 0;
  double runningSum = 0.0;
  double phaseSum = 0.0;
  const bool phase = fr.hasPhase();
  if (phase) out.phaseDeg.resize(n);

  for (std::size_t i = 0; i < n; ++i) {
    const double loF = fr.freqHz[i] / ratio;
    const double hiF = fr.freqHz[i] * ratio;
    while (hi < n && fr.freqHz[hi] <= hiF) {
      runningSum += fr.magDb[hi];
      if (phase) phaseSum += fr.phaseDeg[hi];
      ++hi;
    }
    while (lo < hi && fr.freqHz[lo] < loF) {
      runningSum -= fr.magDb[lo];
      if (phase) phaseSum -= fr.phaseDeg[lo];
      ++lo;
    }
    const std::size_t cnt = hi - lo;
    out.magDb[i] = cnt ? runningSum / static_cast<double>(cnt) : fr.magDb[i];
    // Phase is already unwrapped, so a plain average is meaningful here.
    if (phase) {
      out.phaseDeg[i] =
          cnt ? phaseSum / static_cast<double>(cnt) : fr.phaseDeg[i];
    }
  }
  return out;
}

// Linear interpolation of `ys` over log-frequency; clamps at the edges.
static double interpAt(const std::vector<double>& xs,
                       const std::vector<double>& ys, double f) {
  if (f <= xs.front()) return ys.front();
  if (f >= xs.back()) return ys.back();
  const auto it = std::lower_bound(xs.begin(), xs.end(), f);
  const std::size_t hi = static_cast<std::size_t>(it - xs.begin());
  const std::size_t lo = hi - 1;
  const double t = (std::log(f) - std::log(xs[lo])) /
                   (std::log(xs[hi]) - std::log(xs[lo]));
  return ys[lo] + t * (ys[hi] - ys[lo]);
}

FreqResponse resampleLog(const FreqResponse& fr, double fMin, double fMax,
                         std::size_t points) {
  FreqResponse out;
  if (points == 0 || fr.freqHz.empty()) return out;
  out.freqHz.resize(points);
  out.magDb.resize(points);
  const bool phase = fr.hasPhase();
  if (phase) out.phaseDeg.resize(points);
  const double logMin = std::log(fMin);
  const double logMax = std::log(fMax);
  for (std::size_t i = 0; i < points; ++i) {
    const double t = static_cast<double>(i) / (points - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    out.freqHz[i] = f;
    out.magDb[i] = interpAt(fr.freqHz, fr.magDb, f);
    // Safe to interpolate directly because the phase is unwrapped.
    if (phase) out.phaseDeg[i] = interpAt(fr.freqHz, fr.phaseDeg, f);
  }
  return out;
}

FreqResponse responseSpread(const std::vector<FreqResponse>& measurements) {
  FreqResponse out;
  if (measurements.empty()) return out;
  out.freqHz = measurements.front().freqHz;
  out.magDb.assign(out.freqHz.size(), 0.0);
  if (measurements.size() < 2) return out;  // one capture says nothing about spread

  for (std::size_t i = 0; i < out.freqHz.size(); ++i) {
    double sum = 0.0;
    std::size_t n = 0;
    for (const auto& m : measurements) {
      if (i >= m.magDb.size()) continue;
      sum += m.magDb[i];
      ++n;
    }
    if (n < 2) continue;
    const double mean = sum / static_cast<double>(n);
    double var = 0.0;
    for (const auto& m : measurements) {
      if (i >= m.magDb.size()) continue;
      const double d = m.magDb[i] - mean;
      var += d * d;
    }
    out.magDb[i] = std::sqrt(var / static_cast<double>(n - 1));
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
