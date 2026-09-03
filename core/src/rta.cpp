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

}  // namespace

RtaAnalyzer::RtaAnalyzer(const RtaConfig& cfg) : cfg_(cfg) {
  if (cfg_.fftSize < 64) cfg_.fftSize = 64;
  cfg_.fftSize = nextPow2(cfg_.fftSize);
  cfg_.overlap = std::clamp(cfg_.overlap, 0.0, 0.9);
  cfg_.averaging = std::clamp(cfg_.averaging, 0.01, 1.0);

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

  const std::size_t bins = cfg_.fftSize / 2;
  freqHz_.resize(bins);
  for (std::size_t i = 0; i < bins; ++i) {
    freqHz_[i] = static_cast<double>(i) * cfg_.fs / cfg_.fftSize;
  }
  avgDb_.assign(bins, kFloorDb);
  peakDb_.assign(bins, kFloorDb);
  pending_.reserve(cfg_.fftSize * 2);
}

std::size_t RtaAnalyzer::push(const double* samples, std::size_t n) {
  if (!samples || n == 0) return 0;
  pending_.insert(pending_.end(), samples, samples + n);

  std::size_t produced = 0;
  while (pending_.size() >= cfg_.fftSize) {
    std::vector<double> block(pending_.begin(),
                              pending_.begin() + cfg_.fftSize);

    double sumSq = 0.0;
    for (double v : block) sumSq += v * v;
    lastLevelDbfs_ = toDb(std::sqrt(sumSq / block.size()));

    for (std::size_t i = 0; i < block.size(); ++i) block[i] *= window_[i];

    const std::vector<Complex> spec = rfft(block, cfg_.fftSize);
    const std::size_t bins = cfg_.fftSize / 2;
    for (std::size_t i = 0; i < bins && i < spec.size(); ++i) {
      // Single-sided amplitude: every bin except DC represents two.
      const double amp =
          std::abs(spec[i]) / cfg_.fftSize * (i == 0 ? 1.0 : 2.0);
      double db = toDb(amp) + windowGainDb_;

      if (cfg_.pinkWeighted && freqHz_[i] > 0.0) {
        // Pink noise falls 3 dB per octave; adding that back makes it flat.
        db += 3.0 * std::log2(freqHz_[i] / 1000.0);
      }

      if (!haveSpectrum_) {
        avgDb_[i] = db;
      } else {
        // Exponential average in the dB domain. Averaging dB rather than power
        // is what an RTA display wants: it weights a brief loud event less, so
        // the picture reflects what is sustained.
        avgDb_[i] = avgDb_[i] + cfg_.averaging * (db - avgDb_[i]);
      }
      if (db > peakDb_[i]) peakDb_[i] = db;
    }
    haveSpectrum_ = true;
    ++produced;

    pending_.erase(pending_.begin(), pending_.begin() + hop_);
  }
  return produced;
}

FreqResponse RtaAnalyzer::shape(const std::vector<double>& magDb) const {
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
}

void RtaAnalyzer::resetPeakHold() {
  std::fill(peakDb_.begin(), peakDb_.end(), kFloorDb);
}

}  // namespace rewcore
