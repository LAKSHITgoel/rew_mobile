#include "rewcore/rta.hpp"

#include <algorithm>
#include <cmath>

#include "rewcore/fft.hpp"

namespace rewcore {
namespace {

constexpr double kFloorDb = -180.0;

double toDb(double amplitude) {
  return amplitude <= 1e-12 ? kFloorDb : 20.0 * std::log10(amplitude);
}

// IEC 61672 A- and C-weighting, the same curves a sound level meter applies.
double aWeightDb(double f) {
  if (f <= 0.0) return kFloorDb;
  const double f2 = f * f;
  const double num = 12194.0 * 12194.0 * f2 * f2;
  const double den = (f2 + 20.6 * 20.6) *
                     std::sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) *
                     (f2 + 12194.0 * 12194.0);
  return 20.0 * std::log10(num / den) + 2.00;
}

double cWeightDb(double f) {
  if (f <= 0.0) return kFloorDb;
  const double f2 = f * f;
  const double num = 12194.0 * 12194.0 * f2;
  const double den = (f2 + 20.6 * 20.6) * (f2 + 12194.0 * 12194.0);
  return 20.0 * std::log10(num / den) + 0.06;
}

// Linear interpolation of a calibration curve onto an arbitrary frequency,
// holding the end values beyond its range.
double interpDb(const std::vector<double>& xs, const std::vector<double>& ys,
                double x) {
  if (xs.empty()) return 0.0;
  if (x <= xs.front()) return ys.front();
  if (x >= xs.back()) return ys.back();
  for (std::size_t i = 1; i < xs.size(); ++i) {
    if (x <= xs[i]) {
      const double t = (x - xs[i - 1]) / (xs[i] - xs[i - 1]);
      return ys[i - 1] + t * (ys[i] - ys[i - 1]);
    }
  }
  return ys.back();
}

}  // namespace

RtaAnalyzer::RtaAnalyzer(const RtaConfig& cfg) : cfg_(cfg) {
  if (cfg_.fftSize < 64) cfg_.fftSize = 64;
  cfg_.fftSize = nextPow2(cfg_.fftSize);
  cfg_.overlap = std::clamp(cfg_.overlap, 0.0, 0.9);
  if (cfg_.averageCount < 1) cfg_.averageCount = 1;
  if (cfg_.bandsPerOctave < 1.0) cfg_.bandsPerOctave = 1.0;

  hop_ = static_cast<std::size_t>(cfg_.fftSize * (1.0 - cfg_.overlap));
  if (hop_ == 0) hop_ = 1;

  // Hann. Its sidelobes fall away fast, which matters here: a loud low-frequency
  // mode would otherwise leak across the whole display and hide everything else.
  window_.resize(cfg_.fftSize);
  double sum = 0.0;
  for (std::size_t i = 0; i < cfg_.fftSize; ++i) {
    window_[i] =
        0.5 * (1.0 - std::cos(2.0 * M_PI * i / (cfg_.fftSize - 1)));
    sum += window_[i];
  }
  // A window throws away energy; without correcting for it every level would
  // read low by a fixed amount, which matters as soon as the mic is calibrated
  // and the numbers are supposed to be SPL.
  const double coherentGain = sum / cfg_.fftSize;
  windowGainDb_ = -toDb(coherentGain);

  double sumSq = 0.0;
  for (double w : window_) sumSq += w * w;
  enbwBins_ = cfg_.fftSize * sumSq / (sum * sum);

  const std::size_t bins = cfg_.fftSize / 2;
  freqHz_.resize(bins);
  for (std::size_t i = 0; i < bins; ++i) {
    freqHz_[i] = static_cast<double>(i) * cfg_.fs / cfg_.fftSize;
  }
  avgDb_.assign(bins, kFloorDb);
  peakDb_.assign(bins, kFloorDb);

  // Resolve the calibration and the weighting onto the bin grid once, rather
  // than per block: both are fixed for the analyser's life.
  calDb_.assign(bins, 0.0);
  weightDb_.assign(bins, 0.0);
  const bool haveCal = cfg_.calFreqHz.size() == cfg_.calGainDb.size() &&
                       !cfg_.calFreqHz.empty();
  for (std::size_t i = 0; i < bins; ++i) {
    const double f = freqHz_[i];
    if (haveCal) {
      // Subtracted, not added: the file describes the microphone's own
      // response, and the point is to remove it from what is displayed.
      calDb_[i] = -interpDb(cfg_.calFreqHz, cfg_.calGainDb, f);
    }
    switch (cfg_.weighting) {
      case SplWeighting::a:
        weightDb_[i] = aWeightDb(f);
        break;
      case SplWeighting::c:
        weightDb_[i] = cWeightDb(f);
        break;
      case SplWeighting::z:
        weightDb_[i] = 0.0;
        break;
    }
  }
  pending_.reserve(cfg_.fftSize * 2);
}

std::size_t RtaAnalyzer::push(const double* samples, std::size_t n) {
  if (!samples || n == 0) return 0;
  pending_.insert(pending_.end(), samples, samples + n);

  std::size_t produced = 0;
  while (pending_.size() >= cfg_.fftSize) {
    std::vector<double> block(pending_.begin(),
                              pending_.begin() + cfg_.fftSize);

    for (std::size_t i = 0; i < block.size(); ++i) block[i] *= window_[i];

    const std::vector<Complex> spec = rfft(block, cfg_.fftSize);
    const std::size_t bins = cfg_.fftSize / 2;
    double levelPower = 0.0;
    for (std::size_t i = 0; i < bins && i < spec.size(); ++i) {
      // Single-sided amplitude: every bin except DC represents two.
      const double amp =
          std::abs(spec[i]) / cfg_.fftSize * (i == 0 ? 1.0 : 2.0);
      // Calibration first: it is a property of the microphone and belongs on
      // the measurement before anything is derived from it, including the
      // level readout.
      double db = toDb(amp) + windowGainDb_ + calDb_[i];

      // The weighted level is accumulated from the calibrated spectrum rather
      // than from the raw block, so A- and C-weighting mean what a sound level
      // meter means by them.
      const double weighted = db + weightDb_[i];
      levelPower += std::pow(10.0, weighted / 10.0);

      if (cfg_.pinkWeighted && freqHz_[i] > 0.0) {
        // Pink noise falls 3 dB per octave; adding that back makes it flat.
        db += 3.0 * std::log2(freqHz_[i] / 1000.0);
      }

      switch (cfg_.averagingMode) {
        case RtaAveraging::none:
          avgDb_[i] = db;
          break;
        case RtaAveraging::forever: {
          // A true cumulative mean: every spectrum since the reset counts the
          // same, which is what "forever" has to mean for it to settle.
          const double n = static_cast<double>(averagedCount_ + 1);
          avgDb_[i] = haveSpectrum_ ? avgDb_[i] + (db - avgDb_[i]) / n : db;
          break;
        }
        case RtaAveraging::exponential:
          // Weight 1/count, so "8 averages" behaves like a running average of
          // eight — the way REW expresses it, rather than as a coefficient.
          avgDb_[i] = haveSpectrum_
                          ? avgDb_[i] + (db - avgDb_[i]) / cfg_.averageCount
                          : db;
          break;
      }
      if (db > peakDb_[i]) peakDb_[i] = db;
    }
    // Amplitude spectrum, so the sum of squared bin amplitudes is the mean
    // square of the signal; halve it to get RMS for sinusoidal components.
    // Halved to turn summed amplitude-squared into mean square, and divided by
    // the window's noise bandwidth, without which a broadband level reads 1.76
    // dB high on a Hann window.
    lastLevelDbfs_ = levelPower <= 0.0
                         ? kFloorDb
                         : 10.0 * std::log10(levelPower / (2.0 * enbwBins_));
    haveSpectrum_ = true;
    ++averagedCount_;
    ++produced;

    pending_.erase(pending_.begin(), pending_.begin() + hop_);
  }
  return produced;
}

// Sum the energy in each 1/N octave band, which is how an RTA is normally
// read. Not the same as smoothing the FFT: a band is the total in an interval,
// so a tone lands in one band at its true level instead of being spread across
// neighbouring bins by the window.
FreqResponse RtaAnalyzer::toOctaveBands(const std::vector<double>& magDb) const {
  FreqResponse out;
  const double n = cfg_.bandsPerOctave;
  const double halfWidth = std::pow(2.0, 0.5 / n);
  const double binWidth = cfg_.fs / cfg_.fftSize;

  // Bands centred on 1 kHz, as the standard ones are.
  const int kLo = static_cast<int>(std::floor(std::log2(cfg_.fMin / 1000.0) * n));
  const int kHi = static_cast<int>(std::ceil(std::log2(cfg_.fMax / 1000.0) * n));
  for (int k = kLo; k <= kHi; ++k) {
    const double centre = 1000.0 * std::pow(2.0, k / n);
    if (centre < cfg_.fMin || centre > cfg_.fMax) continue;
    const double lo = centre / halfWidth;
    const double hi = centre * halfWidth;

    double power = 0.0;
    std::size_t counted = 0;
    for (std::size_t i = 1; i < freqHz_.size(); ++i) {
      if (freqHz_[i] < lo) continue;
      if (freqHz_[i] > hi) break;
      power += std::pow(10.0, magDb[i] / 10.0);
      ++counted;
    }
    if (counted == 0) {
      // Narrower than one bin, down at the bottom of the range: take the
      // nearest bin rather than reporting silence.
      const std::size_t idx =
          std::min(freqHz_.size() - 1,
                   static_cast<std::size_t>(std::lround(centre / binWidth)));
      if (idx == 0) continue;
      power = std::pow(10.0, magDb[idx] / 10.0);
    }
    out.freqHz.push_back(centre);
    // Same noise-bandwidth correction: a band is a sum over bins.
    out.magDb.push_back(
        10.0 * std::log10(std::max(power / enbwBins_, 1e-18)));
  }
  return out;
}

FreqResponse RtaAnalyzer::shape(const std::vector<double>& magDb) const {
  if (cfg_.octaveBands) return toOctaveBands(magDb);
  FreqResponse fr;
  // Skip DC: its bin is meaningless here and would drag smoothing at the bottom.
  for (std::size_t i = 1; i < freqHz_.size(); ++i) {
    fr.freqHz.push_back(freqHz_[i]);
    fr.magDb.push_back(magDb[i]);
  }
  if (fr.freqHz.empty()) return fr;
  if (cfg_.smoothFrac > 0.0) {
    fr = smoothFractionalOctave(fr, cfg_.smoothFrac);
  }
  if (cfg_.points > 0) {
    fr = resampleLog(fr, cfg_.fMin, cfg_.fMax, cfg_.points);
  }
  return fr;
}

FreqResponse RtaAnalyzer::spectrum() const { return shape(avgDb_); }

FreqResponse RtaAnalyzer::peakHold() const { return shape(peakDb_); }

void RtaAnalyzer::resetAveraging() {
  std::fill(avgDb_.begin(), avgDb_.end(), kFloorDb);
  haveSpectrum_ = false;
  averagedCount_ = 0;
}

void RtaAnalyzer::resetPeakHold() {
  std::fill(peakDb_.begin(), peakDb_.end(), kFloorDb);
}

}  // namespace rewcore
