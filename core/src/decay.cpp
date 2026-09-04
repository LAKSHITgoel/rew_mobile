#include "rewcore/decay.hpp"

#include <algorithm>
#include <cmath>

#include "rewcore/biquad.hpp"
#include "rewcore/fft.hpp"

namespace rewcore {
namespace {

double hann(std::size_t i, std::size_t n) {
  if (n < 2) return 1.0;
  return 0.5 * (1.0 - std::cos(2.0 * M_PI * i / (n - 1)));
}

/// Envelope of a real signal via its analytic signal: forward transform, drop
/// the negative frequencies and double the positive ones, transform back, take
/// the magnitude. Without this an impulse response's "decay" is a solid band of
/// oscillation whose outline you have to guess at.
std::vector<double> analyticEnvelope(const std::vector<double>& x) {
  const std::size_t n = nextPow2(x.size());
  std::vector<Complex> spec(n, Complex(0.0, 0.0));
  for (std::size_t i = 0; i < x.size(); ++i) spec[i] = Complex(x[i], 0.0);
  fft(spec, false);

  const std::size_t half = n / 2;
  for (std::size_t i = 1; i < half; ++i) spec[i] *= 2.0;
  for (std::size_t i = half + 1; i < n; ++i) spec[i] = Complex(0.0, 0.0);
  fft(spec, true);

  std::vector<double> env(x.size());
  for (std::size_t i = 0; i < x.size(); ++i) env[i] = std::abs(spec[i]);
  return env;
}

/// Fourth-order bandpass, as two cascaded second-order sections each way. One
/// section per end is not enough separation to call a decay "the decay at
/// 63 Hz" — neighbouring bands leak in and flatten every difference.
std::vector<double> bandpass(const std::vector<double>& x, double centerHz,
                             double bandsPerOctave, double fs) {
  const double halfWidth = std::pow(2.0, 0.5 / std::max(0.25, bandsPerOctave));
  const double lo = centerHz / halfWidth;
  const double hi = std::min(centerHz * halfWidth, fs * 0.49);
  if (lo <= 0.0 || hi <= lo) return {};

  const Biquad hp = makeHighPass(lo, fs);
  const Biquad lp = makeLowPass(hi, fs);

  std::vector<double> y = x;
  for (const Biquad& b : {hp, hp, lp, lp}) {
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (double& v : y) {
      const double in = v;
      const double out = b.b0 * in + b.b1 * x1 + b.b2 * x2 - b.a1 * y1 - b.a2 * y2;
      x2 = x1;
      x1 = in;
      y2 = y1;
      y1 = out;
      v = out;
    }
  }
  return y;
}

/// Schroeder backward integration: the decay curve is what is LEFT of the
/// energy from each moment onward, not the energy at that moment. Integrating
/// backwards is what turns one noisy impulse response into the smooth curve
/// that averaging many noise bursts would have given.
std::vector<double> schroederDb(const std::vector<double>& band) {
  std::vector<double> tail(band.size(), 0.0);
  double sum = 0.0;
  for (std::size_t i = band.size(); i-- > 0;) {
    sum += band[i] * band[i];
    tail[i] = sum;
  }
  if (tail.empty() || tail[0] <= 0.0) return {};
  const double ref = tail[0];
  std::vector<double> db(tail.size());
  for (std::size_t i = 0; i < tail.size(); ++i) {
    db[i] = tail[i] <= 0.0 ? -240.0 : 10.0 * std::log10(tail[i] / ref);
  }
  return db;
}

struct LineFit {
  double slope = 0.0;   // dB per sample
  double r2 = 0.0;
  bool ok = false;
};

LineFit fitLine(const std::vector<double>& db, std::size_t from, std::size_t to) {
  LineFit out;
  if (to <= from + 2 || to > db.size()) return out;
  const double n = static_cast<double>(to - from);
  double sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
  for (std::size_t i = from; i < to; ++i) {
    const double x = static_cast<double>(i);
    const double y = db[i];
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
    syy += y * y;
  }
  const double denom = n * sxx - sx * sx;
  if (std::fabs(denom) < 1e-9) return out;
  out.slope = (n * sxy - sx * sy) / denom;
  const double varY = n * syy - sy * sy;
  if (varY > 1e-12) {
    const double cov = n * sxy - sx * sy;
    out.r2 = (cov * cov) / (denom * varY);
  }
  out.ok = out.slope < 0.0;
  return out;
}

/// First index at or below `level` dB, or the size if it never gets there.
std::size_t crossing(const std::vector<double>& db, double level) {
  for (std::size_t i = 0; i < db.size(); ++i) {
    if (db[i] <= level) return i;
  }
  return db.size();
}

}  // namespace

ImpulseResponse computeImpulseResponse(const std::vector<double>& emitted,
                                       const std::vector<double>& recorded,
                                       const ImpulseSpec& spec) {
  ImpulseResponse out;
  out.fs = spec.fs;
  if (emitted.empty() || recorded.empty() || spec.fs <= 0.0) return out;

  const std::vector<double> ir = deconvolve(emitted, recorded);
  if (ir.size() < 32) return out;

  const std::size_t peak =
      static_cast<std::size_t>(std::lround(irPeakIndex(ir))) % ir.size();
  const std::size_t pre =
      static_cast<std::size_t>(std::max(0.0, spec.preMs) * spec.fs / 1000.0);
  const std::size_t post =
      static_cast<std::size_t>(std::max(1.0, spec.postMs) * spec.fs / 1000.0);

  const double peakValue = ir[peak];
  const double scale = std::fabs(peakValue) > 1e-30 ? 1.0 / std::fabs(peakValue) : 1.0;

  out.samples.reserve(pre + post);
  out.timeMs.reserve(pre + post);
  for (std::size_t i = 0; i < pre + post; ++i) {
    // The impulse response is circular, so the pre-arrival window wraps to the
    // end of the buffer rather than being clipped off.
    const std::size_t src = (peak + ir.size() + i - pre) % ir.size();
    out.samples.push_back(ir[src] * scale);
    out.timeMs.push_back((static_cast<double>(i) - static_cast<double>(pre)) *
                         1000.0 / spec.fs);
  }
  out.peakIndex = pre;
  out.inverted = peakValue < 0.0;
  out.valid = true;
  return out;
}

std::vector<double> stepResponse(const ImpulseResponse& ir) {
  if (!ir.valid || ir.samples.empty()) return {};
  std::vector<double> step(ir.samples.size());
  double sum = 0.0;
  for (std::size_t i = 0; i < ir.samples.size(); ++i) {
    sum += ir.samples[i];
    step[i] = sum;
  }
  double largest = 0.0;
  for (const double v : step) largest = std::max(largest, std::fabs(v));
  if (largest > 1e-30) {
    for (double& v : step) v /= largest;
  }
  return step;
}

std::vector<double> energyTimeCurveDb(const ImpulseResponse& ir) {
  if (!ir.valid || ir.samples.empty()) return {};
  const std::vector<double> env = analyticEnvelope(ir.samples);
  double peak = 0.0;
  for (const double v : env) peak = std::max(peak, v);
  if (peak <= 1e-30) return {};
  std::vector<double> db(env.size());
  for (std::size_t i = 0; i < env.size(); ++i) {
    db[i] = env[i] <= 1e-12 * peak ? -120.0 : 20.0 * std::log10(env[i] / peak);
  }
  return db;
}

Waterfall computeWaterfall(const ImpulseResponse& ir, const WaterfallSpec& spec) {
  Waterfall out;
  if (!ir.valid || ir.samples.empty()) return out;
  if (spec.slices == 0 || spec.points == 0) return out;

  const double fs = spec.fs > 0.0 ? spec.fs : ir.fs;
  const std::size_t window =
      static_cast<std::size_t>(std::max(1.0, spec.windowMs) * fs / 1000.0);
  const std::size_t step =
      static_cast<std::size_t>(std::max(0.5, spec.sliceSpacingMs) * fs / 1000.0);
  if (window < 16) return out;

  const std::size_t fftSize = nextPow2(window);
  double reference = 0.0;

  for (std::size_t s = 0; s < spec.slices; ++s) {
    const std::size_t start = ir.peakIndex + s * step;
    if (start + 16 >= ir.samples.size()) break;

    const std::size_t take = std::min(window, ir.samples.size() - start);
    std::vector<double> slice(take);
    for (std::size_t i = 0; i < take; ++i) {
      // Half a Hann, falling: the slice starts at the moment of interest so it
      // must not be faded in, only out.
      const double w = hann(i + take, 2 * take);
      slice[i] = ir.samples[start + i] * w;
    }

    FreqResponse fr;
    const std::vector<Complex> sp = rfft(slice, fftSize);
    const std::size_t bins = fftSize / 2;
    fr.freqHz.reserve(bins);
    fr.magDb.reserve(bins);
    for (std::size_t i = 1; i < bins && i < sp.size(); ++i) {
      const double mag = std::abs(sp[i]);
      fr.freqHz.push_back(static_cast<double>(i) * fs / fftSize);
      fr.magDb.push_back(mag <= 1e-15 ? -240.0 : 20.0 * std::log10(mag));
    }
    if (fr.freqHz.empty()) break;

    const FreqResponse grid = resampleLog(fr, spec.fMin, spec.fMax, spec.points);
    if (out.freqHz.empty()) out.freqHz = grid.freqHz;
    if (s == 0) {
      for (const double v : grid.magDb) reference = std::max(reference, v);
    }
    out.magDb.push_back(grid.magDb);
    out.timeMs.push_back(static_cast<double>(s * step) * 1000.0 / fs);
  }

  if (out.magDb.empty()) return out;
  // Everything relative to the loudest point of the first slice, so the plot
  // reads as "how far it has fallen" rather than as an absolute level that
  // depends on how loud the sweep happened to be played.
  for (std::vector<double>& row : out.magDb) {
    for (double& v : row) v -= reference;
  }
  out.valid = true;
  return out;
}

DecayResult analyzeDecay(const ImpulseResponse& ir, const DecaySpec& spec) {
  DecayResult out;
  if (!ir.valid || ir.samples.empty()) return out;
  const double fs = spec.fs > 0.0 ? spec.fs : ir.fs;
  const double perOctave = std::max(0.5, spec.bandsPerOctave);

  // Decay is measured from the arrival onward; anything before it is the noise
  // floor the impulse rose out of and would flatten the start of every curve.
  const std::vector<double> tail(ir.samples.begin() + ir.peakIndex,
                                 ir.samples.end());
  if (tail.size() < static_cast<std::size_t>(fs * 0.02)) return out;

  double sum = 0.0;
  int counted = 0;
  const double ratio = std::pow(2.0, 1.0 / perOctave);
  for (double f = spec.fMin; f <= spec.fMax * 1.0001; f *= ratio) {
    const std::vector<double> band = bandpass(tail, f, perOctave, fs);
    if (band.empty()) continue;
    const std::vector<double> db = schroederDb(band);

    BandDecay bd;
    bd.centerHz = f;
    if (db.empty()) {
      out.bands.push_back(bd);
      continue;
    }

    // How far the decay actually got before it flattened into noise. The
    // backward integral stops falling once it is integrating noise, so the
    // level it settles at is the noise floor for this band.
    double lowest = 0.0;
    for (const double v : db) lowest = std::min(lowest, v);
    bd.usableRangeDb = -lowest;

    // Skip the first 5 dB: the very start of a decay is the direct sound, not
    // the decay, and including it bends the line.
    const std::size_t start = crossing(db, -5.0);

    // Take the longest span the measurement can honestly support.
    struct Option { double drop; DecayBasis basis; };
    const Option options[] = {
        {35.0, DecayBasis::t30},
        {25.0, DecayBasis::t20},
        {15.0, DecayBasis::t10},
    };
    for (const Option& opt : options) {
      const std::size_t end = crossing(db, -opt.drop);
      // Require a real margin below the fitted span, so the line is not being
      // drawn partly through the noise floor it is about to hit.
      if (end >= db.size() || bd.usableRangeDb < opt.drop + 5.0) continue;
      const LineFit fit = fitLine(db, start, end);
      if (!fit.ok) continue;
      // Slope is dB per sample; 60 dB at that slope is the extrapolated RT60.
      bd.rt60Sec = -60.0 / (fit.slope * fs);
      bd.straightness = fit.r2;
      bd.basis = opt.basis;
      break;
    }

    // Early decay: the first 10 dB, which is nearer to what is heard. Where it
    // is much shorter than the late decay, something is ringing on after the
    // sound has apparently stopped.
    const std::size_t edtEnd = crossing(db, -10.0);
    if (edtEnd < db.size()) {
      const LineFit fit = fitLine(db, 0, edtEnd);
      if (fit.ok) bd.edtSec = -60.0 / (fit.slope * fs);
    }

    if (bd.basis != DecayBasis::none) {
      sum += bd.rt60Sec;
      ++counted;
    }
    out.bands.push_back(bd);
  }

  if (out.bands.empty()) return out;
  out.averageRt60Sec = counted > 0 ? sum / counted : 0.0;
  out.valid = true;
  return out;
}

}  // namespace rewcore
