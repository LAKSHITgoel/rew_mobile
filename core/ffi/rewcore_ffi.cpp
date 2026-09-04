#include "rewcore_ffi.h"

#include <algorithm>
#include <vector>

#include "rewcore/calibration.hpp"
#include "rewcore/crossover.hpp"
#include "rewcore/distortion.hpp"
#include "rewcore/dsp.hpp"
#include "rewcore/peq.hpp"
#include "rewcore/rta.hpp"

using namespace rewcore;

extern "C" {

const char* rew_version(void) { return "0.1.0"; }

size_t rew_generate_sweep(double fs, double f1, double f2, double durationSec,
                          double* out, size_t cap) {
  SweepSpec spec;
  spec.fs = fs;
  spec.f1 = f1;
  spec.f2 = f2;
  spec.durationSec = durationSec;
  const std::vector<double> sweep = generateExpSweep(spec);
  if (out == nullptr) return sweep.size();       // length query
  if (cap < sweep.size()) return 0;              // won't truncate silently
  std::copy(sweep.begin(), sweep.end(), out);
  return sweep.size();
}

double rew_rms_dbfs(const double* samples, size_t n) {
  if (!samples || n == 0) return -240.0;
  return rmsDbfs(std::vector<double>(samples, samples + n));
}

size_t rew_generate_noise(double fs, double durationSec, double fLo, double fHi,
                          double amplitude, unsigned int seed, double* out,
                          size_t cap) {
  NoiseSpec spec;
  spec.fs = fs;
  spec.durationSec = durationSec;
  spec.fLo = fLo;
  spec.fHi = fHi;
  spec.amplitude = amplitude;
  spec.seed = seed;
  const std::vector<double> noise = generatePinkNoise(spec);
  if (out == nullptr) return noise.size();
  if (cap < noise.size()) return 0;
  std::copy(noise.begin(), noise.end(), out);
  return noise.size();
}

size_t rew_measure_request_size(void) { return sizeof(rew_measure_request); }

size_t rew_measure_fr(const rew_measure_request* req) {
  if (!req || !req->emitted || !req->recorded || !req->freqOut || !req->magOut) {
    return 0;
  }
  std::vector<double> em(req->emitted, req->emitted + req->emittedLen);
  std::vector<double> rec(req->recorded, req->recorded + req->recordedLen);

  const std::vector<double> ir = deconvolve(em, rec);
  const FreqResponse raw =
      frequencyResponse(ir, req->fs, 0, req->timeReferencePhase != 0);

  MicCalibration cal;
  const bool haveCal = req->calFreq && req->calGain && req->calN > 0;
  if (haveCal) {
    cal.freqHz.assign(req->calFreq, req->calFreq + req->calN);
    cal.gainDb.assign(req->calGain, req->calGain + req->calN);
  }

  // One deconvolution and one FFT, smoothed two ways: the user's setting for
  // what is drawn, and a fixed fine setting for what the fitter reads.
  auto finish = [&](double frac) {
    FreqResponse fr = frac > 0.0 ? smoothFractionalOctave(raw, frac) : raw;
    if (haveCal) fr = applyMicCalibration(fr, cal);
    return resampleLog(fr, req->fMin, req->fMax,
                       std::min(req->points, req->cap));
  };

  const FreqResponse display = finish(req->smoothFrac);
  for (size_t i = 0; i < display.freqHz.size(); ++i) {
    req->freqOut[i] = display.freqHz[i];
    req->magOut[i] = display.magDb[i];
    if (req->phaseOut) {
      req->phaseOut[i] = display.hasPhase() ? display.phaseDeg[i] : 0.0;
    }
  }

  if (req->magAnalysisOut) {
    const double frac =
        req->analysisSmoothFrac > 0.0 ? req->analysisSmoothFrac : 24.0;
    // Skip the second pass when it would be identical work.
    const FreqResponse analysis =
        frac == req->smoothFrac ? display : finish(frac);
    for (size_t i = 0; i < analysis.magDb.size(); ++i) {
      req->magAnalysisOut[i] = analysis.magDb[i];
    }
  }
  return display.freqHz.size();
}

int rew_assess_capture(const double* samples, size_t n, double fs, double* out) {
  if (!samples || n == 0 || !out) return 0;
  const CaptureQuality q =
      assessCapture(std::vector<double>(samples, samples + n), fs);
  int flags = 0;
  if (q.clipped) flags |= 1;
  if (q.tooQuiet) flags |= 2;
  if (q.mostlySilent) flags |= 4;
  out[0] = q.peak;
  out[1] = q.rmsDbfs;
  out[2] = q.clippedFraction;
  out[3] = q.silentFraction;
  out[4] = static_cast<double>(flags);
  out[5] = q.usable ? 1.0 : 0.0;
  return flags;
}

size_t rew_smooth_response(const double* freq, const double* mag, size_t n,
                           double fractionOfOctave, double* out) {
  if (!freq || !mag || !out || n == 0) return 0;
  FreqResponse fr;
  fr.freqHz.assign(freq, freq + n);
  fr.magDb.assign(mag, mag + n);
  const FreqResponse smoothed =
      fractionOfOctave > 0.0 ? smoothFractionalOctave(fr, fractionOfOctave) : fr;
  for (size_t i = 0; i < n && i < smoothed.magDb.size(); ++i) {
    out[i] = smoothed.magDb[i];
  }
  return smoothed.magDb.size();
}

size_t rew_response_spread(const double* mags, size_t count, size_t n,
                           double* out) {
  if (!mags || !out || count == 0 || n == 0) return 0;
  std::vector<FreqResponse> rs;
  rs.reserve(count);
  for (size_t k = 0; k < count; ++k) {
    FreqResponse r;
    r.freqHz.assign(n, 0.0);  // spread does not depend on the frequency grid
    r.magDb.assign(mags + k * n, mags + (k + 1) * n);
    rs.push_back(std::move(r));
  }
  const FreqResponse s = responseSpread(rs);
  for (size_t i = 0; i < n && i < s.magDb.size(); ++i) out[i] = s.magDb[i];
  return s.magDb.size();
}

size_t rew_peq_request_size(void) { return sizeof(rew_peq_request); }

size_t rew_fit_peq(const rew_peq_request* req) {
  if (!req || !req->freq || !req->mag || !req->freqOut || !req->gainOut ||
      !req->qOut) {
    return 0;
  }
  const size_t n = req->n;

  FreqResponse measured;
  std::vector<double> spreadDb;
  // `valid` marks the points the sweep actually cleared the noise by. Dropping
  // the rest is the whole game: fitting to noise is what produced -12 dB bands
  // for a subwoofer. Points are simply omitted, which keeps every downstream
  // statistic (level alignment, passband reference, error) over real data only.
  if (req->valid) {
    for (size_t i = 0; i < n; ++i) {
      if (!req->valid[i]) continue;
      measured.freqHz.push_back(req->freq[i]);
      measured.magDb.push_back(req->mag[i]);
      if (req->spread) spreadDb.push_back(req->spread[i]);
    }
    if (measured.freqHz.size() < 4) return 0;  // nothing trustworthy to fit
  } else {
    measured.freqHz.assign(req->freq, req->freq + n);
    measured.magDb.assign(req->mag, req->mag + n);
    if (req->spread) spreadDb.assign(req->spread, req->spread + n);
  }

  PeqConstraints c;
  c.fs = req->fs;
  c.fMin = req->fMin;
  c.fMax = req->fMax;
  c.maxBands = req->maxBands;
  if (req->targetPercentile > 0.0) c.targetPercentile = req->targetPercentile;
  if (req->maxCutDb > 0.0) c.maxCutDb = req->maxCutDb;
  if (req->maxBoostDb > 0.0) c.maxBoostDb = req->maxBoostDb;

  TargetShape shape;
  shape.bassShelfDb = req->bassShelfDb;
  if (req->bassShelfHz > 0.0) shape.bassShelfHz = req->bassShelfHz;
  if (req->bassShelfWidthOct > 0.0) {
    shape.bassShelfWidthOct = req->bassShelfWidthOct;
  }
  shape.tiltDbPerOctave = req->tiltDbPerOctave;
  if (req->tiltPivotHz > 0.0) shape.tiltPivotHz = req->tiltPivotHz;

  const PeqFitResult res =
      fitPeq(measured, makeTarget(measured, shape), c, spreadDb);
  for (size_t i = 0; i < res.bands.size(); ++i) {
    req->freqOut[i] = res.bands[i].freqHz;
    req->gainOut[i] = res.bands[i].gainDb;
    req->qOut[i] = res.bands[i].q;
    if (req->reasonOut && i < res.rationale.size()) {
      req->reasonOut[i] = static_cast<int>(res.rationale[i].reason);
    }
    if (req->confOut && i < res.rationale.size()) {
      req->confOut[i] = res.rationale[i].confidence;
    }
  }

  size_t declinedCount = 0;
  if (req->declinedOut) {
    for (const auto& d : res.declined) {
      if (declinedCount >= req->declinedCap) break;
      req->declinedOut[declinedCount * 2] = static_cast<double>(d.reason);
      req->declinedOut[declinedCount * 2 + 1] = d.freqHz;
      ++declinedCount;
    }
  }
  if (req->errOut) {
    req->errOut[0] = res.initialErrorDb;
    req->errOut[1] = res.finalErrorDb;
    req->errOut[2] = res.suggestedLevelTrimDb;
    req->errOut[3] = static_cast<double>(declinedCount);
  }
  return res.bands.size();
}

size_t rew_summation_result_size(void) {
  return sizeof(rew_summation_result);
}

int rew_analyze_summation(const double* freq, const double* aMag,
                          const double* bMag, const double* bothMag,
                          const double* bothInvertedMag, size_t n,
                          double overlapDropDb, rew_summation_result* out) {
  if (!freq || !aMag || !bMag || !bothMag || !out || n == 0) return 0;

  auto build = [&](const double* mag) {
    FreqResponse fr;
    if (!mag) return fr;
    fr.freqHz.assign(freq, freq + n);
    fr.magDb.assign(mag, mag + n);
    return fr;
  };

  const SummationAnalysis r = analyzeSummation(
      build(aMag), build(bMag), build(bothMag), build(bothInvertedMag),
      overlapDropDb > 0.0 ? overlapDropDb : 10.0);

  out->valid = r.valid ? 1 : 0;
  out->haveInverted = r.haveInverted ? 1 : 0;
  out->advice = static_cast<int>(r.advice);
  out->overlapLoHz = r.overlapLoHz;
  out->overlapHiHz = r.overlapHiHz;
  out->measuredDb = r.measuredDb;
  out->invertedDb = r.invertedDb;
  out->coherentDb = r.coherentDb;
  out->powerDb = r.powerDb;
  out->deficitDb = r.deficitDb;
  out->invertedGainDb = r.invertedGainDb;
  out->confidence = r.confidence;
  return r.valid ? 1 : 0;
}

size_t rew_crossover_result_size(void) {
  return sizeof(rew_crossover_result);
}

static void fillEdge(rew_crossover_edge* dst, const CrossoverEdge& src) {
  dst->present = src.present ? 1 : 0;
  dst->reason = static_cast<int>(src.reason);
  dst->freqHz = src.freqHz;
  dst->recommendedHz = src.recommendedHz;
  dst->acousticSlopeDbPerOct = src.acousticSlopeDbPerOct;
  dst->electricalSlopeDbPerOct = src.electricalSlopeDbPerOct;
  dst->confidence = src.confidence;
}

int rew_recommend_crossover(const double* freq, const double* mag, size_t n,
                            double dropDb, double targetAcousticDbPerOct,
                            double marginOctaves, rew_crossover_result* out) {
  if (!freq || !mag || !out) return 0;
  FreqResponse driver;
  driver.freqHz.assign(freq, freq + n);
  driver.magDb.assign(mag, mag + n);
  const CrossoverRecommendation rec = recommendCrossover(
      driver, dropDb,
      targetAcousticDbPerOct > 0.0 ? targetAcousticDbPerOct : 24.0,
      marginOctaves > 0.0 ? marginOctaves : 0.33);

  fillEdge(&out->highPass, rec.highPass);
  fillEdge(&out->lowPass, rec.lowPass);
  out->passbandDb = rec.passbandDb;

  int mask = 0;
  if (rec.highPass.present) mask |= 1;
  if (rec.lowPass.present) mask |= 2;
  return mask;
}

}  // extern "C"

// --- Real-time analyser -----------------------------------------------------

size_t rew_distortion_request_size(void) {
  return sizeof(rew_distortion_request);
}

size_t rew_distortion(const rew_distortion_request* req) {
  if (!req || !req->emitted || !req->recorded) return 0;
  if (!req->freqOut || req->cap == 0) return 0;

  DistortionSpec spec;
  if (req->fs > 0.0) spec.fs = req->fs;
  if (req->f1 > 0.0) spec.f1 = req->f1;
  if (req->f2 > 0.0) spec.f2 = req->f2;
  if (req->durationSec > 0.0) spec.durationSec = req->durationSec;
  if (req->fMin > 0.0) spec.fMin = req->fMin;
  if (req->fMax > 0.0) spec.fMax = req->fMax;
  if (req->maxHarmonic > 0) spec.maxHarmonic = req->maxHarmonic;
  spec.points = req->points > 0 ? std::min(req->points, req->cap) : req->cap;

  const std::vector<double> emitted(req->emitted, req->emitted + req->emittedLen);
  const std::vector<double> recorded(req->recorded,
                                     req->recorded + req->recordedLen);
  const DistortionResult r = analyzeDistortion(emitted, recorded, spec);
  if (!r.valid) return 0;

  const size_t n = std::min(req->cap, r.fundamental.freqHz.size());
  for (size_t i = 0; i < n; ++i) {
    req->freqOut[i] = r.fundamental.freqHz[i];
    if (req->fundamentalOut) req->fundamentalOut[i] = r.fundamental.magDb[i];
    if (req->thdPercentOut) req->thdPercentOut[i] = r.thdPercent.magDb[i];
  }
  if (req->harmonicsOut) {
    for (size_t h = 0; h < r.harmonics.size(); ++h) {
      for (size_t i = 0; i < n; ++i) {
        req->harmonicsOut[h * n + i] = r.harmonics[h].magDb[i];
      }
    }
  }
  if (req->worstOut) {
    req->worstOut[0] = r.worstThdPercent;
    req->worstOut[1] = r.worstThdHz;
  }
  return n;
}

struct rew_rta {
  explicit rew_rta(const RtaConfig& c) : impl(c) {}
  RtaAnalyzer impl;
};

size_t rew_rta_config_size(void) { return sizeof(rew_rta_config); }

rew_rta* rew_rta_create(const rew_rta_config* cfg) {
  RtaConfig c;
  if (cfg) {
    if (cfg->fs > 0.0) c.fs = cfg->fs;
    if (cfg->fftSize > 0) c.fftSize = cfg->fftSize;
    if (cfg->overlap > 0.0) c.overlap = cfg->overlap;
    switch (cfg->averagingMode) {
      case 0: c.averagingMode = RtaAveraging::none; break;
      case 2: c.averagingMode = RtaAveraging::forever; break;
      default: c.averagingMode = RtaAveraging::exponential; break;
    }
    if (cfg->averageCount > 0) c.averageCount = cfg->averageCount;
    if (cfg->bandsPerOctave > 0.0) c.bandsPerOctave = cfg->bandsPerOctave;
    c.octaveBands = cfg->octaveBands != 0;
    switch (cfg->weighting) {
      case 1: c.weighting = SplWeighting::a; break;
      case 2: c.weighting = SplWeighting::c; break;
      default: c.weighting = SplWeighting::z; break;
    }
    if (cfg->calFreqHz && cfg->calGainDb && cfg->calN > 0) {
      c.calFreqHz.assign(cfg->calFreqHz, cfg->calFreqHz + cfg->calN);
      c.calGainDb.assign(cfg->calGainDb, cfg->calGainDb + cfg->calN);
    }
    if (cfg->smoothFrac < 0.0) {
      c.smoothFrac = 0.0;
    } else if (cfg->smoothFrac > 0.0) {
      c.smoothFrac = cfg->smoothFrac;
    }
    if (cfg->fMin > 0.0) c.fMin = cfg->fMin;
    if (cfg->fMax > 0.0) c.fMax = cfg->fMax;
    c.points = cfg->points;
    c.pinkWeighted = cfg->pinkWeighted != 0;
  }
  return new rew_rta(c);
}

void rew_rta_destroy(rew_rta* rta) { delete rta; }

size_t rew_rta_push(rew_rta* rta, const double* samples, size_t n) {
  if (!rta || !samples) return 0;
  return rta->impl.push(samples, n);
}

static size_t copyOut(const FreqResponse& fr, double* freqOut, double* magOut,
                      size_t cap) {
  if (!freqOut || !magOut) return 0;
  const size_t n = std::min(cap, fr.freqHz.size());
  for (size_t i = 0; i < n; ++i) {
    freqOut[i] = fr.freqHz[i];
    magOut[i] = fr.magDb[i];
  }
  return n;
}

size_t rew_rta_spectrum(rew_rta* rta, double* freqOut, double* magOut,
                        size_t cap) {
  if (!rta || !rta->impl.hasSpectrum()) return 0;
  return copyOut(rta->impl.spectrum(), freqOut, magOut, cap);
}

size_t rew_rta_peak_hold(rew_rta* rta, double* freqOut, double* magOut,
                         size_t cap) {
  if (!rta || !rta->impl.hasSpectrum()) return 0;
  return copyOut(rta->impl.peakHold(), freqOut, magOut, cap);
}

double rew_rta_level_dbfs(rew_rta* rta) {
  return rta ? rta->impl.levelDbfs() : -240.0;
}

void rew_rta_reset(rew_rta* rta, int averaging, int peakHold) {
  if (!rta) return;
  if (averaging) rta->impl.resetAveraging();
  if (peakHold) rta->impl.resetPeakHold();
}
