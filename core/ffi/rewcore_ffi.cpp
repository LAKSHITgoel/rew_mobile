#include "rewcore_ffi.h"

#include <algorithm>
#include <vector>

#include "rewcore/calibration.hpp"
#include "rewcore/crossover.hpp"
#include "rewcore/dsp.hpp"
#include "rewcore/peq.hpp"

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

size_t rew_measure_fr(const double* emitted, size_t emittedLen,
                      const double* recorded, size_t recordedLen, double fs,
                      double fMin, double fMax, double smoothFrac, size_t points,
                      const double* calFreq, const double* calGain, size_t calN,
                      int timeReferencePhase, double* freqOut, double* magOut,
                      double* phaseOut, size_t cap) {
  if (!emitted || !recorded || !freqOut || !magOut) return 0;
  std::vector<double> em(emitted, emitted + emittedLen);
  std::vector<double> rec(recorded, recorded + recordedLen);

  const std::vector<double> ir = deconvolve(em, rec);
  FreqResponse fr = frequencyResponse(ir, fs, 0, timeReferencePhase != 0);
  if (smoothFrac > 0.0) fr = smoothFractionalOctave(fr, smoothFrac);

  if (calFreq && calGain && calN > 0) {
    MicCalibration cal;
    cal.freqHz.assign(calFreq, calFreq + calN);
    cal.gainDb.assign(calGain, calGain + calN);
    fr = applyMicCalibration(fr, cal);
  }

  const size_t n = std::min(points, cap);
  const FreqResponse grid = resampleLog(fr, fMin, fMax, n);
  for (size_t i = 0; i < grid.freqHz.size(); ++i) {
    freqOut[i] = grid.freqHz[i];
    magOut[i] = grid.magDb[i];
    if (phaseOut) {
      phaseOut[i] = grid.hasPhase() ? grid.phaseDeg[i] : 0.0;
    }
  }
  return grid.freqHz.size();
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

  const PeqFitResult res = fitPeq(measured, flatTarget(measured), c, spreadDb);
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

int rew_recommend_crossover(const double* freq, const double* mag, size_t n,
                            double dropDb, double* hpOut, double* lpOut) {
  if (!freq || !mag) return 0;
  FreqResponse driver;
  driver.freqHz.assign(freq, freq + n);
  driver.magDb.assign(mag, mag + n);
  const CrossoverRecommendation rec = recommendCrossover(driver, dropDb);
  int mask = 0;
  if (rec.hasHighPass) {
    mask |= 1;
    if (hpOut) *hpOut = rec.highPassHz;
  }
  if (rec.hasLowPass) {
    mask |= 2;
    if (lpOut) *lpOut = rec.lowPassHz;
  }
  return mask;
}

}  // extern "C"
