#include "rewcore/distortion.hpp"

#include <algorithm>
#include <cmath>

#include "rewcore/fft.hpp"

namespace rewcore {
namespace {

// Magnitude spectrum of a gated section of the impulse response, on the same
// log grid as everything else the app draws.
FreqResponse spectrumOf(const std::vector<double>& ir, std::size_t centre,
                        std::size_t halfWidth, double fs) {
  FreqResponse out;
  if (ir.empty() || halfWidth == 0) return out;

  const std::size_t n = ir.size();
  const std::size_t width = halfWidth * 2;
  std::vector<double> gated(width, 0.0);
  for (std::size_t i = 0; i < width; ++i) {
    // The impulse response is circular: a harmonic sitting "before" the linear
    // arrival is at the far end of the buffer, so the index has to wrap rather
    // than be clamped away.
    const std::size_t src = (centre + n - halfWidth + i) % n;
    // Hann across the gate, so the window's own edges do not appear as
    // broadband content that would read as distortion.
    const double w =
        0.5 * (1.0 - std::cos(2.0 * M_PI * i / (width - 1)));
    gated[i] = ir[src] * w;
  }

  const std::size_t fftSize = nextPow2(width);
  const std::vector<Complex> spec = rfft(gated, fftSize);
  const std::size_t bins = fftSize / 2;
  out.freqHz.reserve(bins);
  out.magDb.reserve(bins);
  for (std::size_t i = 1; i < bins && i < spec.size(); ++i) {
    const double mag = std::abs(spec[i]);
    out.freqHz.push_back(static_cast<double>(i) * fs / fftSize);
    out.magDb.push_back(mag <= 1e-12 ? -240.0 : 20.0 * std::log10(mag));
  }
  return out;
}

double interpDb(const FreqResponse& fr, double f) {
  if (fr.freqHz.empty()) return -240.0;
  if (f <= fr.freqHz.front()) return fr.magDb.front();
  if (f >= fr.freqHz.back()) return fr.magDb.back();
  for (std::size_t i = 1; i < fr.freqHz.size(); ++i) {
    if (f <= fr.freqHz[i]) {
      const double t =
          (f - fr.freqHz[i - 1]) / (fr.freqHz[i] - fr.freqHz[i - 1]);
      return fr.magDb[i - 1] + t * (fr.magDb[i] - fr.magDb[i - 1]);
    }
  }
  return fr.magDb.back();
}

}  // namespace

DistortionResult analyzeDistortion(const std::vector<double>& emitted,
                                   const std::vector<double>& recorded,
                                   const DistortionSpec& spec) {
  DistortionResult out;
  if (emitted.empty() || recorded.empty()) return out;
  if (spec.f2 <= spec.f1 || spec.durationSec <= 0.0) return out;
  const int maxH = std::clamp(spec.maxHarmonic, 2, 8);

  const std::vector<double> ir = deconvolve(emitted, recorded);
  if (ir.size() < 64) return out;

  const std::size_t peak =
      static_cast<std::size_t>(std::lround(irPeakIndex(ir))) % ir.size();

  // Where each harmonic lands, in samples ahead of the linear arrival.
  const double sweepRate = std::log(spec.f2 / spec.f1);
  std::vector<std::size_t> offsets(maxH + 1, 0);
  for (int h = 2; h <= maxH; ++h) {
    const double dt = spec.durationSec * std::log(static_cast<double>(h)) / sweepRate;
    offsets[h] = static_cast<std::size_t>(std::lround(dt * spec.fs));
  }

  // Gate half-width: half the distance to the nearest neighbouring arrival, so
  // one harmonic's window never reaches into the next. The gaps shrink as the
  // order climbs, which is the real reason for stopping around the fifth.
  auto halfWidthFor = [&](int h) -> std::size_t {
    std::size_t nearest = offsets[h];  // distance back to the linear arrival
    for (int k = 2; k <= maxH; ++k) {
      if (k == h) continue;
      const std::size_t d = offsets[k] > offsets[h] ? offsets[k] - offsets[h]
                                                    : offsets[h] - offsets[k];
      nearest = std::min(nearest, d);
    }
    return std::max<std::size_t>(32, nearest / 2);
  };

  // The linear response, gated the same way so the comparison is fair.
  const std::size_t linearHalf = maxH >= 2 ? halfWidthFor(2) : ir.size() / 4;
  const FreqResponse linear = spectrumOf(ir, peak, linearHalf, spec.fs);
  if (linear.freqHz.empty()) return out;
  out.fundamental = resampleLog(linear, spec.fMin, spec.fMax, spec.points);

  // Each harmonic, replotted against the fundamental that produced it: energy
  // measured at frequency F on the Nth harmonic was generated when the sweep
  // was at F/N.
  out.harmonics.reserve(maxH - 1);
  for (int h = 2; h <= maxH; ++h) {
    const std::size_t centre = (peak + ir.size() - offsets[h]) % ir.size();
    const FreqResponse raw = spectrumOf(ir, centre, halfWidthFor(h), spec.fs);

    FreqResponse mapped;
    mapped.freqHz.reserve(out.fundamental.freqHz.size());
    mapped.magDb.reserve(out.fundamental.freqHz.size());
    for (const double f : out.fundamental.freqHz) {
      mapped.freqHz.push_back(f);
      mapped.magDb.push_back(interpDb(raw, f * h));
    }
    out.harmonics.push_back(mapped);
  }

  // THD as a percentage: the harmonics summed in power against the fundamental.
  out.thdPercent.freqHz = out.fundamental.freqHz;
  out.thdPercent.magDb.assign(out.fundamental.freqHz.size(), 0.0);
  for (std::size_t i = 0; i < out.fundamental.freqHz.size(); ++i) {
    const double fundDb = out.fundamental.magDb[i];
    double harmonicPower = 0.0;
    for (const FreqResponse& h : out.harmonics) {
      const double rel = h.magDb[i] - fundDb;
      harmonicPower += std::pow(10.0, rel / 10.0);
    }
    const double percent = 100.0 * std::sqrt(harmonicPower);
    // Above the top of the sweep divided by the harmonic order there is no
    // measurement, only whatever the gate picked up, so it is not reported.
    const double highestUseful = spec.f2 / 2.0;
    out.thdPercent.magDb[i] =
        out.fundamental.freqHz[i] <= highestUseful ? percent : 0.0;
    if (out.thdPercent.magDb[i] > out.worstThdPercent) {
      out.worstThdPercent = out.thdPercent.magDb[i];
      out.worstThdHz = out.fundamental.freqHz[i];
    }
  }

  out.valid = true;
  return out;
}

}  // namespace rewcore
