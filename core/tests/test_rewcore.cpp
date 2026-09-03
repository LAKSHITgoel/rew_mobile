// Desktop test harness for rewcore. Runs the DSP pipeline against synthetic signals
// with known answers, so correctness is verifiable with no audio hardware.
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "rewcore/biquad.hpp"
#include "rewcore/calibration.hpp"
#include "rewcore/crossover.hpp"
#include "rewcore/dsp.hpp"
#include "rewcore/fft.hpp"
#include "rewcore/peq.hpp"
#include "rewcore/wav.hpp"
#include "rewcore_ffi.h"

using namespace rewcore;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                       \
  do {                                                                    \
    ++g_checks;                                                           \
    if (!(cond)) {                                                        \
      ++g_failures;                                                       \
      std::printf("  FAIL: %s (line %d)\n", #cond, __LINE__);             \
    }                                                                     \
  } while (0)

#define CHECK_NEAR(a, b, tol)                                             \
  do {                                                                    \
    ++g_checks;                                                           \
    const double _a = (a), _b = (b), _t = (tol);                          \
    if (std::fabs(_a - _b) > _t) {                                        \
      ++g_failures;                                                       \
      std::printf("  FAIL: |%.6g - %.6g| > %.6g  [%s vs %s] (line %d)\n", \
                  _a, _b, _t, #a, #b, __LINE__);                          \
    }                                                                     \
  } while (0)

// Apply a biquad (direct form I) to a signal — used to synthesize a known system.
static std::vector<double> applyBiquad(const Biquad& bq,
                                       const std::vector<double>& x) {
  std::vector<double> y(x.size(), 0.0);
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (std::size_t n = 0; n < x.size(); ++n) {
    const double out =
        bq.b0 * x[n] + bq.b1 * x1 + bq.b2 * x2 - bq.a1 * y1 - bq.a2 * y2;
    x2 = x1;
    x1 = x[n];
    y2 = y1;
    y1 = out;
    y[n] = out;
  }
  return y;
}

// Linear interpolation of a FreqResponse at frequency f (linear in frequency).
static double frAt(const FreqResponse& fr, double f) {
  if (f <= fr.freqHz.front()) return fr.magDb.front();
  if (f >= fr.freqHz.back()) return fr.magDb.back();
  for (std::size_t i = 1; i < fr.freqHz.size(); ++i) {
    if (fr.freqHz[i] >= f) {
      const double t =
          (f - fr.freqHz[i - 1]) / (fr.freqHz[i] - fr.freqHz[i - 1]);
      return fr.magDb[i - 1] + t * (fr.magDb[i] - fr.magDb[i - 1]);
    }
  }
  return fr.magDb.back();
}

static void testFftRoundTrip() {
  std::printf("test: FFT round-trip & bin location\n");
  const std::size_t N = 1024;
  std::vector<Complex> x(N);
  for (std::size_t i = 0; i < N; ++i) x[i] = Complex(std::sin(0.1 * i) + 0.3 * i, 0);
  std::vector<Complex> X = x;
  fft(X, false);
  fft(X, true);
  double maxErr = 0;
  for (std::size_t i = 0; i < N; ++i)
    maxErr = std::max(maxErr, std::abs(X[i] - x[i]));
  CHECK(maxErr < 1e-9);

  // A pure cosine at bin 64 should peak at bin 64.
  std::vector<double> sig(N);
  for (std::size_t i = 0; i < N; ++i)
    sig[i] = std::cos(2.0 * M_PI * 64.0 * i / N);
  std::vector<Complex> S = rfft(sig, N);
  std::size_t peak = 1;
  double best = 0;
  for (std::size_t i = 1; i < N / 2; ++i) {
    if (std::abs(S[i]) > best) {
      best = std::abs(S[i]);
      peak = i;
    }
  }
  CHECK(peak == 64);
}

static void testBiquadAnalytic() {
  std::printf("test: biquad analytic magnitude\n");
  const double fs = 48000;
  Biquad bq = makePeaking(1000.0, fs, 6.0, 2.0);
  CHECK_NEAR(bq.magnitudeDb(1000.0, fs), 6.0, 0.05);
  CHECK_NEAR(bq.magnitudeDb(50.0, fs), 0.0, 0.3);
  CHECK_NEAR(bq.magnitudeDb(18000.0, fs), 0.0, 0.5);
}

static void testDeconvolutionDelay() {
  std::printf("test: deconvolution recovers a pure delay\n");
  SweepSpec spec;
  spec.fs = 48000;
  spec.f1 = 100;
  spec.f2 = 12000;
  spec.durationSec = 0.5;
  const std::vector<double> emitted = generateExpSweep(spec);

  const std::size_t D = 500;
  std::vector<double> recorded(D + emitted.size(), 0.0);
  for (std::size_t i = 0; i < emitted.size(); ++i) recorded[D + i] = emitted[i];

  const std::vector<double> ir = deconvolve(emitted, recorded);
  const double peak = irPeakIndex(ir);
  CHECK_NEAR(peak, static_cast<double>(D), 1.0);
}

static void testDeconvolutionMagnitude() {
  std::printf("test: deconvolution recovers a known biquad magnitude\n");
  const double fs = 48000;
  SweepSpec spec;
  spec.fs = fs;
  spec.f1 = 50;
  spec.f2 = 18000;
  spec.durationSec = 1.0;
  std::vector<double> emitted = generateExpSweep(spec);

  // System under test: a +6 dB peaking filter at 1 kHz, Q 2.
  Biquad sys = makePeaking(1000.0, fs, 6.0, 2.0);
  std::vector<double> padded = emitted;
  padded.insert(padded.end(), 4096, 0.0);  // capture the decay tail
  const std::vector<double> recorded = applyBiquad(sys, padded);

  const std::vector<double> ir = deconvolve(emitted, recorded);
  const FreqResponse fr = frequencyResponse(ir, fs);

  for (double f : {300.0, 1000.0, 3000.0, 6000.0}) {
    CHECK_NEAR(frAt(fr, f), sys.magnitudeDb(f, fs), 0.75);
  }
}

static void testPeqFitReducesError() {
  std::printf("test: PEQ auto-fit reduces error toward flat\n");
  const double fs = 48000;
  // Synthesize a bumpy measured response: a bass hump + a presence dip.
  std::vector<PeqBand> distortion = {{80.0, 8.0, 1.0}, {3000.0, -6.0, 1.5}};
  FreqResponse measured;
  const std::size_t pts = 300;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (std::size_t i = 0; i < pts; ++i) {
    const double t = static_cast<double>(i) / (pts - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    measured.freqHz.push_back(f);
    measured.magDb.push_back(cascadeMagnitudeDb(distortion, f, fs));
  }

  PeqConstraints c;
  c.fs = fs;
  c.maxBands = 8;
  const PeqFitResult res = fitPeq(measured, flatTarget(measured), c);

  CHECK(!res.bands.empty());
  CHECK(res.initialErrorDb > 1.0);
  CHECK(res.finalErrorDb < res.initialErrorDb);
  CHECK(res.finalErrorDb < 0.6 * res.initialErrorDb);
  std::printf("  initial=%.3f dB rms, final=%.3f dB rms, bands=%zu\n",
              res.initialErrorDb, res.finalErrorDb, res.bands.size());

  // No two bands should stack closer than the minimum spacing.
  for (std::size_t i = 0; i < res.bands.size(); ++i)
    for (std::size_t j = i + 1; j < res.bands.size(); ++j)
      CHECK(std::fabs(std::log2(res.bands[i].freqHz / res.bands[j].freqHz)) >=
            c.minSpacingOctave - 1e-9);
}

static void testPeqQEstimation() {
  std::printf("test: PEQ auto-fit estimates wide vs narrow Q\n");
  const double fs = 48000;
  // A wide bass hump (Q 0.7) and a narrow midrange dip (Q 4).
  std::vector<PeqBand> distortion = {{120.0, 8.0, 0.7}, {5000.0, -8.0, 4.0}};
  FreqResponse measured;
  const std::size_t pts = 400;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (std::size_t i = 0; i < pts; ++i) {
    const double t = static_cast<double>(i) / (pts - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    measured.freqHz.push_back(f);
    measured.magDb.push_back(cascadeMagnitudeDb(distortion, f, fs));
  }
  PeqConstraints c;
  c.fs = fs;
  c.maxBands = 6;
  const PeqFitResult res = fitPeq(measured, flatTarget(measured), c);

  // Find the fitted band nearest each injected feature and compare their Q.
  auto nearest = [&](double f) {
    double bestQ = 0;
    double bestDist = 1e9;
    for (const auto& b : res.bands) {
      const double d = std::fabs(std::log2(b.freqHz / f));
      if (d < bestDist) {
        bestDist = d;
        bestQ = b.q;
      }
    }
    return bestQ;
  };
  const double qBass = nearest(120.0);
  const double qMid = nearest(5000.0);
  std::printf("  Q near 120Hz hump = %.2f, Q near 5kHz dip = %.2f\n", qBass, qMid);
  CHECK(qBass < qMid);   // wide feature -> lower Q than narrow feature
}

static void testCrossoverSummation() {
  std::printf("test: Linkwitz-Riley crossover sums flat\n");
  const SummationCheck s = checkSummation(2000.0, Slope::LinkwitzRiley24,
                                          Slope::LinkwitzRiley24, 200.0, 20000.0);
  CHECK(s.maxDeviationDb < 0.01);

  // Each branch is -6 dB at the crossover frequency.
  CHECK_NEAR(20.0 * std::log10(lowpassMagnitude(2000.0, 2000.0,
                                                 Slope::LinkwitzRiley24)),
             -6.0206, 0.01);
}

static void testSmoothingMatchesReference() {
  std::printf("test: fractional-octave smoothing matches a naive reference\n");
  // The shipped smoother slides a window with a running sum (O(n)); this checks it
  // against the obvious O(n^2) definition so the optimization can't drift.
  FreqResponse fr;
  const std::size_t pts = 400;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (std::size_t i = 0; i < pts; ++i) {
    const double t = static_cast<double>(i) / (pts - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    fr.freqHz.push_back(f);
    // A wiggly curve so the window content actually varies.
    fr.magDb.push_back(3.0 * std::sin(i * 0.35) + 0.01 * i);
  }

  const double frac = 24.0;
  const FreqResponse fast = smoothFractionalOctave(fr, frac);

  const double ratio = std::pow(2.0, 1.0 / (2.0 * frac));
  double worst = 0.0;
  for (std::size_t i = 0; i < pts; ++i) {
    const double lo = fr.freqHz[i] / ratio, hi = fr.freqHz[i] * ratio;
    double acc = 0.0;
    std::size_t cnt = 0;
    for (std::size_t j = 0; j < pts; ++j) {
      if (fr.freqHz[j] >= lo && fr.freqHz[j] <= hi) {
        acc += fr.magDb[j];
        ++cnt;
      }
    }
    const double ref = cnt ? acc / cnt : fr.magDb[i];
    worst = std::max(worst, std::fabs(ref - fast.magDb[i]));
  }
  std::printf("  worst deviation from reference: %.3g dB\n", worst);
  CHECK(worst < 1e-9);

  // A flat input must stay flat.
  FreqResponse flat = fr;
  for (auto& m : flat.magDb) m = -3.0;
  const FreqResponse sm = smoothFractionalOctave(flat, frac);
  for (std::size_t i = 0; i < pts; ++i) CHECK_NEAR(sm.magDb[i], -3.0, 1e-9);
}

static void testRecommendCrossover() {
  std::printf("test: measured crossover recommendation\n");
  // Synthesize a band-limited driver: high-passed at 500 Hz, low-passed at 5000 Hz.
  FreqResponse driver;
  const std::size_t pts = 200;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (std::size_t i = 0; i < pts; ++i) {
    const double t = static_cast<double>(i) / (pts - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    const double hp = highpassMagnitude(f, 500.0, Slope::LinkwitzRiley24);
    const double lp = lowpassMagnitude(f, 5000.0, Slope::LinkwitzRiley24);
    driver.freqHz.push_back(f);
    driver.magDb.push_back(20.0 * std::log10(hp * lp));
  }
  const CrossoverRecommendation rec = recommendCrossover(driver, 6.0);
  CHECK(rec.hasHighPass);
  CHECK(rec.hasLowPass);
  std::printf("  suggested HPF=%.0f Hz, LPF=%.0f Hz\n", rec.highPassHz, rec.lowPassHz);
  CHECK(rec.highPassHz > 420 && rec.highPassHz < 600);
  CHECK(rec.lowPassHz > 4200 && rec.lowPassHz < 6000);
}

static void testFfiCalibration() {
  std::printf("test: FFI measurement applies mic calibration\n");
  // Identity system: recorded == emitted -> flat 0 dB measured response.
  SweepSpec spec;
  spec.fs = 48000;
  spec.f1 = 50;
  spec.f2 = 18000;
  spec.durationSec = 1.0;
  const std::vector<double> sweep = generateExpSweep(spec);

  const int points = 48;
  std::vector<double> f1(points), m1(points), f2(points), m2(points);

  const size_t n1 = rew_measure_fr(sweep.data(), sweep.size(), sweep.data(),
                                   sweep.size(), spec.fs, 50, 18000, 24, points,
                                   nullptr, nullptr, 0, 0, f1.data(), m1.data(), nullptr, points);

  // A flat +3 dB mic calibration should pull the measured response down by 3 dB.
  std::vector<double> calF = {20, 20000};
  std::vector<double> calG = {3, 3};
  const size_t n2 = rew_measure_fr(sweep.data(), sweep.size(), sweep.data(),
                                   sweep.size(), spec.fs, 50, 18000, 24, points,
                                   calF.data(), calG.data(), calF.size(),
                                   0, f2.data(), m2.data(), nullptr, points);
  CHECK(n1 == n2 && n1 > 0);
  // Compare a mid-band point.
  const std::size_t mid = n1 / 2;
  CHECK_NEAR(m1[mid] - m2[mid], 3.0, 0.3);
}

static void testFfiPeqErrorOut() {
  std::printf("test: FFI PEQ fit reports error metrics\n");
  const double fs = 48000;
  std::vector<PeqBand> distortion = {{90.0, 7.0, 1.0}, {4000.0, -6.0, 2.0}};
  const int n = 200;
  std::vector<double> freq(n), mag(n);
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (int i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / (n - 1);
    freq[i] = std::exp(logMin + t * (logMax - logMin));
    mag[i] = cascadeMagnitudeDb(distortion, freq[i], fs);
  }
  std::vector<double> fo(10), go(10), qo(10), err(4), conf(10), decl(20);
  std::vector<int> rsn(10);
  const size_t bands = rew_fit_peq_flat(
      freq.data(), mag.data(), n, fs, 20, 20000, 10, 0.0, 0.0, nullptr, nullptr,
      fo.data(), go.data(), qo.data(), rsn.data(), conf.data(), decl.data(), 10,
      err.data());
  CHECK(bands > 0);
  CHECK(err[0] > 1.0);          // initial error meaningful
  CHECK(err[1] < err[0]);       // EQ reduced it

  // No band may exceed the practical cut depth: a -12 dB band does not correct
  // a channel, it mutes it — which is what happened to a subwoofer in the car.
  for (size_t i = 0; i < bands; ++i) CHECK(go[i] >= -6.0 - 1e-9);

  // A validity mask must confine the fit to the points it marks. Marking only
  // the bottom of the range as trustworthy is what stops noise above the
  // Bluetooth link's cutoff from being "corrected".
  std::vector<unsigned char> valid(n, 0);
  for (int i = 0; i < n; ++i) valid[i] = freq[i] < 500.0 ? 1 : 0;
  const size_t masked = rew_fit_peq_flat(
      freq.data(), mag.data(), n, fs, 20, 20000, 10, 0.0, 0.0, valid.data(),
      nullptr, fo.data(), go.data(), qo.data(), rsn.data(), conf.data(),
      decl.data(), 10, err.data());
  CHECK(masked > 0);
  for (size_t i = 0; i < masked; ++i) CHECK(fo[i] < 500.0);

  // Every band must come back with a reason and a usable confidence: a bare
  // frequency/gain/Q is not enough to decide whether to type it into a DSP.
  for (size_t i = 0; i < bands; ++i) {
    CHECK(rsn[i] != 0);
    CHECK(conf[i] > 0.0 && conf[i] <= 1.0);
  }
}

static void testConfidenceAndRepeatability() {
  std::printf("test: confidence scoring, and unrepeatable features left alone\n");
  const double fs = 48000.0;
  const int n = 200;
  FreqResponse fr;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (int i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / (n - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    fr.freqHz.push_back(f);
    // One broad excess at 1 kHz, one at 5 kHz.
    const double broad = 6.0 * std::exp(-std::pow(std::log2(f / 1000.0), 2) / 0.5);
    const double other = 6.0 * std::exp(-std::pow(std::log2(f / 5000.0), 2) / 0.5);
    fr.magDb.push_back(broad + other);
  }

  PeqConstraints c;
  c.fs = fs;
  c.maxBands = 6;

  // With no repeated captures, both peaks are fair game.
  const PeqFitResult plain = fitPeq(fr, flatTarget(fr), c);
  CHECK(!plain.bands.empty());
  CHECK(plain.rationale.size() == plain.bands.size());
  for (const auto& r : plain.rationale) {
    CHECK(r.confidence > 0.0 && r.confidence <= 1.0);
  }

  // Now say the 5 kHz region moved wildly between captures: it must not be
  // corrected, and the fitter must say so rather than omit it silently.
  std::vector<double> spread(fr.freqHz.size(), 0.4);
  for (std::size_t i = 0; i < fr.freqHz.size(); ++i) {
    if (fr.freqHz[i] > 3500.0 && fr.freqHz[i] < 7000.0) spread[i] = 6.0;
  }
  const PeqFitResult gated = fitPeq(fr, flatTarget(fr), c, spread);
  for (const auto& b : gated.bands) {
    CHECK(!(b.freqHz > 3500.0 && b.freqHz < 7000.0));
  }
  bool saidUnrepeatable = false;
  for (const auto& d : gated.declined) {
    if (d.reason == PeqReason::declinedUnrepeatable) saidUnrepeatable = true;
  }
  CHECK(saidUnrepeatable);

  // A repeatable broad peak should score higher than the same peak measured
  // sloppily — the whole point of scoring confidence.
  std::vector<double> tight(fr.freqHz.size(), 0.3);
  std::vector<double> loose(fr.freqHz.size(), 2.5);
  const PeqFitResult a = fitPeq(fr, flatTarget(fr), c, tight);
  const PeqFitResult b = fitPeq(fr, flatTarget(fr), c, loose);
  CHECK(!a.rationale.empty() && !b.rationale.empty());
  CHECK(a.rationale[0].confidence > b.rationale[0].confidence);
}

static void testResponseSpread() {
  std::printf("test: repeatability across repeated captures\n");
  FreqResponse a, b, cc;
  for (int i = 0; i < 10; ++i) {
    const double f = 100.0 * (i + 1);
    a.freqHz.push_back(f); b.freqHz.push_back(f); cc.freqHz.push_back(f);
    a.magDb.push_back(0.0);
    b.magDb.push_back(i == 5 ? 6.0 : 0.0);   // one point disagrees badly
    cc.magDb.push_back(i == 5 ? -6.0 : 0.0);
  }
  const FreqResponse s = responseSpread({a, b, cc});
  CHECK(s.magDb[0] < 1e-9);   // agreed everywhere else
  CHECK(s.magDb[5] > 3.0);    // and disagreed here
  // A single capture cannot say anything about repeatability.
  CHECK(responseSpread({a}).magDb[5] < 1e-9);
}

static void testPeqReportsLevelTrim() {
  std::printf("test: broad excess comes back as a level trim, not a mute\n");
  const double fs = 48000.0;
  const int n = 200;
  std::vector<double> freq(n), mag(n);
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (int i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / (n - 1);
    freq[i] = std::exp(logMin + t * (logMax - logMin));
    // A wide, deep bass excess, like cabin gain on a subwoofer channel.
    mag[i] = freq[i] < 80.0 ? 14.0 : 0.0;
  }
  std::vector<double> fo(10), go(10), qo(10), err(4), conf(10), decl(20);
  std::vector<int> rsn(10);
  const size_t bands = rew_fit_peq_flat(
      freq.data(), mag.data(), n, fs, 20, 20000, 10, 0.0, 6.0, nullptr, nullptr,
      fo.data(), go.data(), qo.data(), rsn.data(), conf.data(), decl.data(), 10,
      err.data());
  CHECK(bands > 0);
  for (size_t i = 0; i < bands; ++i) CHECK(go[i] >= -6.0 - 1e-9);
  CHECK(err[2] > 0.0);  // and it says how far to turn the channel down
}

// Mean magnitude (dB) of a signal's spectrum between two frequencies.
static double bandLevelDb(const std::vector<double>& x, double fs, double f1,
                          double f2) {
  const std::size_t N = nextPow2(x.size());
  const std::vector<Complex> spec = rfft(x, N);
  double acc = 0.0;
  std::size_t cnt = 0;
  for (std::size_t i = 1; i < N / 2; ++i) {
    const double f = static_cast<double>(i) * fs / N;
    if (f >= f1 && f <= f2) {
      acc += std::abs(spec[i]);
      ++cnt;
    }
  }
  return cnt ? 20.0 * std::log10(acc / cnt + 1e-12) : -240.0;
}

// Linear interpolation of a response's phase at a frequency.
static double phaseAt(const FreqResponse& fr, double f) {
  if (f <= fr.freqHz.front()) return fr.phaseDeg.front();
  if (f >= fr.freqHz.back()) return fr.phaseDeg.back();
  for (std::size_t i = 1; i < fr.freqHz.size(); ++i) {
    if (fr.freqHz[i] >= f) {
      const double t =
          (f - fr.freqHz[i - 1]) / (fr.freqHz[i] - fr.freqHz[i - 1]);
      return fr.phaseDeg[i - 1] + t * (fr.phaseDeg[i] - fr.phaseDeg[i - 1]);
    }
  }
  return fr.phaseDeg.back();
}

static void testPhaseUnwrap() {
  std::printf("test: phase unwrapping\n");
  // A sawtooth that really represents a continuous downward ramp.
  std::vector<double> p = {170, -170, -150, 170, 150};
  unwrapPhaseDeg(p);
  for (std::size_t i = 1; i < p.size(); ++i) {
    CHECK(std::fabs(p[i] - p[i - 1]) <= 180.0 + 1e-9);
  }
  // 170 -> -170 is really +20 degrees, not -340.
  CHECK_NEAR(p[1], 190.0, 1e-9);
}

static void testPhaseOfPureDelay() {
  std::printf("test: a pure delay measures as linear phase\n");
  const double fs = 48000;
  SweepSpec spec;
  spec.fs = fs;
  spec.f1 = 50;
  spec.f2 = 18000;
  spec.durationSec = 1.0;
  const std::vector<double> emitted = generateExpSweep(spec);

  const std::size_t D = 32;  // samples of pure delay
  std::vector<double> recorded(D + emitted.size(), 0.0);
  for (std::size_t i = 0; i < emitted.size(); ++i) recorded[D + i] = emitted[i];

  const std::vector<double> ir = deconvolve(emitted, recorded);
  const FreqResponse fr = frequencyResponse(ir, fs);
  CHECK(fr.hasPhase());

  // phase(f) = -360 * f * D / fs, so the slope gives back the delay.
  for (double f : {1000.0, 4000.0, 8000.0}) {
    const double expected = -360.0 * f * static_cast<double>(D) / fs;
    CHECK_NEAR(phaseAt(fr, f), expected, 6.0);
  }
  // Recover the group delay from two points and compare with D.
  const double p1 = phaseAt(fr, 2000.0), p2 = phaseAt(fr, 6000.0);
  const double delaySamples = -(p2 - p1) / 360.0 / (6000.0 - 2000.0) * fs;
  std::printf("  recovered delay %.2f samples (expected %zu)\n", delaySamples, D);
  CHECK_NEAR(delaySamples, static_cast<double>(D), 1.0);
}

static void testTimeReferencedPhase() {
  std::printf("test: time referencing removes bulk delay from phase\n");
  const double fs = 48000;
  SweepSpec spec;
  spec.fs = fs;
  spec.f1 = 50;
  spec.f2 = 18000;
  spec.durationSec = 1.0;
  const std::vector<double> emitted = generateExpSweep(spec);

  // A big flight time, like Bluetooth: 50 ms is ~18000 degrees at 1 kHz.
  const std::size_t D = static_cast<std::size_t>(0.05 * fs);
  std::vector<double> recorded(D + emitted.size(), 0.0);
  for (std::size_t i = 0; i < emitted.size(); ++i) recorded[D + i] = emitted[i];
  const std::vector<double> ir = deconvolve(emitted, recorded);

  const FreqResponse raw = frequencyResponse(ir, fs, 0, false);
  const FreqResponse ref = frequencyResponse(ir, fs, 0, true);

  // Raw phase is swamped by the delay...
  CHECK(std::fabs(phaseAt(raw, 1000.0)) > 1000.0);
  // ...but time-referenced it is essentially flat, because a pure delay has no
  // phase character of its own once the flight time is removed.
  std::printf("  raw %.0f deg -> referenced %.1f deg at 1 kHz\n",
              phaseAt(raw, 1000.0), phaseAt(ref, 1000.0));
  CHECK(std::fabs(phaseAt(ref, 1000.0)) < 20.0);
  CHECK(std::fabs(phaseAt(ref, 5000.0)) < 20.0);

  // Magnitude must be untouched by the rotation.
  CHECK_NEAR(frAt(raw, 1000.0), frAt(ref, 1000.0), 0.01);
}

static void testPhaseOfKnownFilters() {
  std::printf("test: measured phase of known filters\n");
  const double fs = 48000;
  SweepSpec spec;
  spec.fs = fs;
  spec.f1 = 50;
  spec.f2 = 18000;
  spec.durationSec = 1.0;
  const std::vector<double> emitted = generateExpSweep(spec);

  auto measure = [&](const Biquad& bq) {
    std::vector<double> padded = emitted;
    padded.insert(padded.end(), 8192, 0.0);
    const std::vector<double> rec = applyBiquad(bq, padded);
    return frequencyResponse(deconvolve(emitted, rec), fs);
  };

  // A peaking filter is symmetric about its centre: zero phase shift there.
  const FreqResponse peak = measure(makePeaking(1000.0, fs, 6.0, 2.0));
  std::printf("  peaking @1k phase = %.1f deg\n", phaseAt(peak, 1000.0));
  CHECK_NEAR(phaseAt(peak, 1000.0), 0.0, 3.0);

  // A 2nd-order high-pass sits at +90 degrees at its corner.
  const FreqResponse hp = measure(makeHighPass(1000.0, fs));
  std::printf("  2nd-order HP @fc phase = %.1f deg\n", phaseAt(hp, 1000.0));
  CHECK_NEAR(phaseAt(hp, 1000.0), 90.0, 5.0);

  // ...and a 2nd-order low-pass at -90.
  const FreqResponse lp = measure(makeLowPass(1000.0, fs));
  std::printf("  2nd-order LP @fc phase = %.1f deg\n", phaseAt(lp, 1000.0));
  CHECK_NEAR(phaseAt(lp, 1000.0), -90.0, 5.0);
}

static void testRmsDbfs() {
  std::printf("test: RMS dBFS convention and SPL offset\n");
  // A full-scale sine must read -3.01 dBFS (miniDSP's convention), not 0.
  std::vector<double> sine(4800);
  for (std::size_t i = 0; i < sine.size(); ++i)
    sine[i] = std::sin(2.0 * M_PI * 100.0 * i / 48000.0);
  CHECK_NEAR(rmsDbfs(sine), -3.01, 0.02);

  // Halving amplitude drops the level by 6 dB.
  std::vector<double> half = sine;
  for (double& v : half) v *= 0.5;
  CHECK_NEAR(rmsDbfs(half) - rmsDbfs(sine), -6.02, 0.02);

  // Silence floors out rather than returning -inf.
  CHECK(rmsDbfs(std::vector<double>(100, 0.0)) < -200.0);

  // The SPL offset is a pure shift, so channel-to-channel DIFFERENCES are
  // independent of it — which is what level-matching drivers relies on.
  const double a = rmsDbfs(sine), b = rmsDbfs(half);
  CHECK_NEAR(splFromDbfs(a, 110.0) - splFromDbfs(b, 110.0), a - b, 1e-12);
  CHECK_NEAR(splFromDbfs(a, 0.0) - splFromDbfs(b, 0.0), a - b, 1e-12);
}

static void testPinkNoise() {
  std::printf("test: pink noise slope and band limiting\n");
  NoiseSpec spec;
  spec.fs = 48000;
  spec.durationSec = 1.0;
  const std::vector<double> pink = generatePinkNoise(spec);
  CHECK(pink.size() == 48000);

  // Peak is normalised to the requested amplitude.
  double peak = 0;
  for (double v : pink) peak = std::max(peak, std::fabs(v));
  CHECK_NEAR(peak, spec.amplitude, 1e-9);

  // Pink tilts down with frequency: low band louder than high band.
  const double low = bandLevelDb(pink, spec.fs, 100, 200);
  const double high = bandLevelDb(pink, spec.fs, 6400, 12800);
  std::printf("  pink 100-200Hz=%.1f dB, 6.4-12.8kHz=%.1f dB\n", low, high);
  CHECK(low > high + 6.0);  // ~-3 dB/oct over 6 octaves

  // Band-limited noise must be concentrated in its band.
  NoiseSpec bl = spec;
  bl.fLo = 200;
  bl.fHi = 4000;
  const std::vector<double> band = generatePinkNoise(bl);
  const double inBand = bandLevelDb(band, bl.fs, 500, 2000);
  const double below = bandLevelDb(band, bl.fs, 20, 50);
  const double above = bandLevelDb(band, bl.fs, 12000, 20000);
  std::printf("  in=%.1f dB, below=%.1f dB, above=%.1f dB\n", inBand, below, above);
  CHECK(inBand > below + 20.0);
  CHECK(inBand > above + 20.0);
}

static void testCalibrationRealUmikFormat() {
  std::printf("test: parses the real miniDSP UMIK-1 file header\n");
  // miniDSP ships a quoted header rather than a comment marker; we used to miss
  // the sensitivity because we only scanned '*'/'#'/';' lines.
  const std::string text =
      "\"Sens Factor =-0.989dB, SERNO: 7165152\"\n"
      "10.054\t-4.3217\n"
      "1000.000\t0.0000\n"
      "20000.000\t-2.5000\n";
  const MicCalibration cal = parseMicCalibration(text);
  CHECK(cal.freqHz.size() == 3);
  CHECK(cal.hasSensitivity);
  CHECK_NEAR(cal.sensitivityDbFs, -0.989, 1e-9);
  CHECK_NEAR(cal.gainDb[0], -4.3217, 1e-9);
}

static void testPeqFlattensDespiteDeadRegion() {
  std::printf("test: EQ flattens a response that has a dead region\n");
  // The shape that exposed the bug in the car: a usable passband with ripple,
  // plus a region tens of dB down below the driver's cutoff. Averaging that in
  // used to drag the target far below the passband, so the fit "flattened" by
  // attenuating everything instead of levelling the ripple.
  const double fs = 48000;
  FreqResponse fr;
  const std::size_t pts = 96;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (std::size_t i = 0; i < pts; ++i) {
    const double t = static_cast<double>(i) / (pts - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    // Steep roll-off below 120 Hz down to ~-55 dB, plus in-band ripple.
    const double hp = highpassMagnitude(f, 120.0, Slope::LinkwitzRiley48);
    double db = 20.0 * std::log10(std::max(hp, 1e-4));
    db += 5.0 * std::sin(std::log2(f / 100.0) * 2.2);  // ripple to correct
    fr.freqHz.push_back(f);
    fr.magDb.push_back(db);
  }

  PeqConstraints c;
  c.fs = fs;
  c.maxBands = 10;
  const PeqFitResult res = fitPeq(fr, flatTarget(fr), c);

  // Flatness measured over the USABLE band only (the dead region is the
  // speaker's limit, not something EQ should be judged on).
  auto usableRipple = [&](const std::vector<PeqBand>& bands) {
    std::vector<double> v;
    for (std::size_t i = 0; i < fr.freqHz.size(); ++i) {
      const double y = fr.magDb[i] + cascadeMagnitudeDb(bands, fr.freqHz[i], fs);
      if (fr.magDb[i] > -25.0) v.push_back(y);  // in the driver's range
    }
    double mean = 0;
    for (double y : v) mean += y;
    mean /= v.size();
    double acc = 0;
    for (double y : v) acc += (y - mean) * (y - mean);
    return std::sqrt(acc / v.size());
  };

  const double before = usableRipple({});
  const double after = usableRipple(res.bands);
  std::printf("  usable-band ripple %.2f -> %.2f dB with %zu bands\n", before,
              after, res.bands.size());
  CHECK(after < before * 0.7);  // genuinely flatter, not merely quieter

  // And nothing should be placed down in the dead region.
  for (const auto& b : res.bands) CHECK(b.freqHz > 60.0);
}

static void testPeqDoesNotBoostDeadBand() {
  std::printf("test: PEQ never boosts where the driver has no output\n");
  const double fs = 48000;
  // A driver with a steep roll-off below 100 Hz plus a genuine +6 dB peak at 1 kHz.
  FreqResponse fr;
  const std::size_t pts = 300;
  const double logMin = std::log(20.0), logMax = std::log(20000.0);
  for (std::size_t i = 0; i < pts; ++i) {
    const double t = static_cast<double>(i) / (pts - 1);
    const double f = std::exp(logMin + t * (logMax - logMin));
    const double hp = highpassMagnitude(f, 100.0, Slope::LinkwitzRiley48);
    fr.freqHz.push_back(f);
    fr.magDb.push_back(20.0 * std::log10(hp > 1e-9 ? hp : 1e-9) +
                       makePeaking(1000.0, fs, 6.0, 2.0).magnitudeDb(f, fs));
  }

  PeqConstraints c;
  c.fs = fs;
  c.maxBands = 10;
  const PeqFitResult res = fitPeq(fr, flatTarget(fr), c);

  bool cutNear1k = false;
  for (const auto& b : res.bands) {
    // Nothing may be boosted down in the dead band.
    if (b.freqHz < 80.0) CHECK(b.gainDb <= 0.0);
    if (std::fabs(std::log2(b.freqHz / 1000.0)) < 0.5 && b.gainDb < 0) cutNear1k = true;
  }
  std::printf("  %zu bands; legit 1 kHz cut present: %s\n", res.bands.size(),
              cutNear1k ? "yes" : "no");
  CHECK(cutNear1k);  // the real in-band problem is still corrected
}

static void testCalibration() {
  std::printf("test: mic calibration parse & apply\n");
  const std::string text =
      "* miniDSP calibration file\n"
      "* Sens Factor =-1.50dB\n"
      "20 0.5\n"
      "1000 0.0\n"
      "20000 -2.0\n";
  const MicCalibration cal = parseMicCalibration(text);
  CHECK(cal.freqHz.size() == 3);
  CHECK(cal.hasSensitivity);
  CHECK_NEAR(cal.sensitivityDbFs, -1.5, 1e-9);

  FreqResponse fr;
  fr.freqHz = {20.0, 1000.0, 20000.0};
  fr.magDb = {0.0, 0.0, 0.0};
  const FreqResponse out = applyMicCalibration(fr, cal);
  CHECK_NEAR(out.magDb[0], -0.5, 1e-9);   // 0 - 0.5
  CHECK_NEAR(out.magDb[1], 0.0, 1e-9);    // 0 - 0.0
  CHECK_NEAR(out.magDb[2], 2.0, 1e-9);    // 0 - (-2.0)
}

static void testWavRoundTrip() {
  std::printf("test: WAV mono float round-trip\n");
  AudioBuffer buf;
  buf.sampleRate = 48000;
  for (int i = 0; i < 2000; ++i)
    buf.samples.push_back(0.5 * std::sin(0.05 * i));

  const std::string path = "rewcore_test_tmp.wav";
  CHECK(writeWavMonoFloat(path, buf));

  AudioBuffer readback;
  CHECK(readWavMono(path, readback));
  CHECK_NEAR(readback.sampleRate, 48000.0, 1e-6);
  CHECK(readback.samples.size() == buf.samples.size());
  double maxErr = 0;
  for (std::size_t i = 0; i < buf.samples.size(); ++i)
    maxErr = std::max(maxErr, std::fabs(readback.samples[i] - buf.samples[i]));
  CHECK(maxErr < 1e-6);
  std::remove(path.c_str());
}

int main() {
  std::printf("=== rewcore test harness ===\n");
  testFftRoundTrip();
  testBiquadAnalytic();
  testDeconvolutionDelay();
  testDeconvolutionMagnitude();
  testPeqFitReducesError();
  testPeqQEstimation();
  testCrossoverSummation();
  testSmoothingMatchesReference();
  testRecommendCrossover();
  testFfiCalibration();
  testFfiPeqErrorOut();
  testPeqReportsLevelTrim();
  testConfidenceAndRepeatability();
  testResponseSpread();
  testPhaseUnwrap();
  testPhaseOfPureDelay();
  testTimeReferencedPhase();
  testPhaseOfKnownFilters();
  testRmsDbfs();
  testPinkNoise();
  testCalibrationRealUmikFormat();
  testPeqFlattensDespiteDeadRegion();
  testPeqDoesNotBoostDeadBand();
  testCalibration();
  testWavRoundTrip();

  std::printf("=== %d checks, %d failures ===\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
