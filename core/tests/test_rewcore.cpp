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
                                   nullptr, nullptr, 0, f1.data(), m1.data(), points);

  // A flat +3 dB mic calibration should pull the measured response down by 3 dB.
  std::vector<double> calF = {20, 20000};
  std::vector<double> calG = {3, 3};
  const size_t n2 = rew_measure_fr(sweep.data(), sweep.size(), sweep.data(),
                                   sweep.size(), spec.fs, 50, 18000, 24, points,
                                   calF.data(), calG.data(), calF.size(),
                                   f2.data(), m2.data(), points);
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
  std::vector<double> fo(10), go(10), qo(10), err(2);
  const size_t bands = rew_fit_peq_flat(freq.data(), mag.data(), n, fs, 20, 20000,
                                        10, fo.data(), go.data(), qo.data(),
                                        err.data());
  CHECK(bands > 0);
  CHECK(err[0] > 1.0);          // initial error meaningful
  CHECK(err[1] < err[0]);       // EQ reduced it
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
  testCalibrationRealUmikFormat();
  testPeqDoesNotBoostDeadBand();
  testCalibration();
  testWavRoundTrip();

  std::printf("=== %d checks, %d failures ===\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
