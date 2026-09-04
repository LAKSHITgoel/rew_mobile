// Real-time analyser: a continuously updating spectrum of whatever the mic is
// hearing, in the shape REW's RTA presents it.
//
// This is a different instrument from the swept measurement, and it answers
// different questions. A sweep gives a clean transfer function of the system
// and is the right tool for EQ and crossovers. An RTA shows what is happening
// *now*, which is what you want for tasks a sweep cannot help with: finding a
// rattle while you tap the trim, watching a resonance as you move the mic,
// checking pink-noise balance by ear and eye together, or seeing how much
// engine and road noise you are fighting before you trust anything.
//
// Deliberately stateful. It accumulates blocks as they arrive, overlaps them,
// windows each one, and averages the results over time — none of which can be
// expressed as a single call on one buffer.
#ifndef REWCORE_RTA_HPP
#define REWCORE_RTA_HPP

#include <cstddef>
#include <vector>

#include "rewcore/dsp.hpp"

namespace rewcore {

// How successive spectra are combined, in the terms REW uses rather than as an
// opaque coefficient.
enum class RtaAveraging {
  none,         // show each block as it arrives
  exponential,  // a running average that forgets, weighted 1/count
  forever,      // a true cumulative mean over everything since the last reset
};

// Frequency weighting for the level readout. Z is unweighted; A follows the
// ear's poor sensitivity to bass at low levels and is what noise regulations
// quote; C is nearly flat but rolls off the extremes.
enum class SplWeighting { z, a, c };

struct RtaConfig {
  double fs = 48000.0;

  // Longer gives finer frequency resolution and a slower, steadier display.
  // 16384 at 48 kHz is ~2.9 Hz per bin, which resolves room modes; REW's
  // default sits in the same region.
  std::size_t fftSize = 16384;

  // Fraction of a block to advance between analyses. 0.5 (50% overlap) is the
  // usual compromise: every sample is seen by two windows, so a transient
  // cannot fall in a window's null and be missed.
  double overlap = 0.5;

  RtaAveraging averagingMode = RtaAveraging::exponential;

  // Number of spectra in the running average, as REW offers it: 1, 2, 4, 8, 16
  // and so on. Each new spectrum gets a weight of 1/count, so a larger number
  // is slower and steadier. Ignored unless averagingMode is exponential.
  int averageCount = 8;

  // Draw as 1/N octave bands rather than raw FFT lines. This is the display an
  // RTA is normally read in: bands sum the energy in each interval, which is
  // closer to how the ear groups sound, and a band value does not jump around
  // with the exact frequency of a tone the way a single FFT bin does.
  bool octaveBands = false;
  double bandsPerOctave = 24.0;  // 1, 2, 3, 6, 12, 24, 48

  SplWeighting weighting = SplWeighting::z;

  // Fractional-octave smoothing of the displayed spectrum, as in the swept
  // measurement. 0 leaves the raw FFT lines.
  double smoothFrac = 6.0;

  // Subtract pink noise's own -3 dB/octave slope, so pink noise reads as a flat
  // line rather than a ramp. This is what makes an RTA usable for judging
  // balance against a target: with it on, "flat on screen" means "matches the
  // reference", which is the comparison you actually care about.
  bool pinkWeighted = true;

  double fMin = 20.0;
  double fMax = 20000.0;
  std::size_t points = 0;  // 0 = keep the raw FFT grid

  // Microphone calibration, as loaded from the UMIK-1's file. Applied to the
  // spectrum, exactly as it is to a swept measurement — without it the display
  // shows the microphone's own response as much as the car's, and the UMIK-1
  // is several dB from flat at the extremes.
  std::vector<double> calFreqHz;
  std::vector<double> calGainDb;
};

class RtaAnalyzer {
 public:
  explicit RtaAnalyzer(const RtaConfig& cfg);

  // Feed captured samples. Any amount may be pushed at a time; the analyser
  // keeps its own buffer and produces a spectrum whenever it has enough.
  // Returns how many new spectra were folded in by this call.
  std::size_t push(const double* samples, std::size_t n);

  // True once at least one spectrum has been computed.
  bool hasSpectrum() const { return haveSpectrum_; }

  // The current time-averaged spectrum, in dBFS (or pink-weighted dB), smoothed
  // and resampled per the config.
  FreqResponse spectrum() const;

  // The highest level seen at each frequency since the last reset. Peak hold is
  // how you catch something intermittent — a rattle that only happens on one
  // note, or a dropout — which an averaged display hides by design.
  FreqResponse peakHold() const;

  // Broadband level of the most recent block, dBFS, with the configured
  // weighting applied. With a calibrated mic this becomes SPL by adding the
  // offset.
  double levelDbfs() const { return lastLevelDbfs_; }

  void resetAveraging();
  void resetPeakHold();

  const RtaConfig& config() const { return cfg_; }

 private:
  FreqResponse shape(const std::vector<double>& magDb) const;

  RtaConfig cfg_;
  std::vector<double> window_;
  std::vector<double> pending_;   // samples not yet analysed
  std::vector<double> freqHz_;    // bin centres
  std::vector<double> avgDb_;     // running average, dB
  std::vector<double> peakDb_;    // peak hold, dB
  std::vector<double> calDb_;     // calibration resampled onto the bin grid
  std::vector<double> weightDb_;  // A/C weighting per bin
  std::size_t hop_ = 0;
  double windowGainDb_ = 0.0;     // corrects for the window's amplitude loss
  // Equivalent noise bandwidth of the window, in bins (1.5 for Hann). A single
  // bin's amplitude is right after the coherent correction, but SUMMING power
  // across bins then over-counts by exactly this factor, because each bin
  // carries a share of its neighbours' energy.
  double enbwBins_ = 1.0;
  bool haveSpectrum_ = false;
  std::size_t averagedCount_ = 0;  // for the cumulative mean
  double lastLevelDbfs_ = -240.0;

  FreqResponse toOctaveBands(const std::vector<double>& magDb) const;
};

}  // namespace rewcore

#endif  // REWCORE_RTA_HPP
