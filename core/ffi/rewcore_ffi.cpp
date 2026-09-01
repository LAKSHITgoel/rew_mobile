#include "rewcore_ffi.h"

#include <algorithm>
#include <vector>

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

size_t rew_measure_fr(const double* emitted, size_t emittedLen,
                      const double* recorded, size_t recordedLen, double fs,
                      double fMin, double fMax, double smoothFrac, size_t points,
                      double* freqOut, double* magOut, size_t cap) {
  if (!emitted || !recorded || !freqOut || !magOut) return 0;
  std::vector<double> em(emitted, emitted + emittedLen);
  std::vector<double> rec(recorded, recorded + recordedLen);

  const std::vector<double> ir = deconvolve(em, rec);
  FreqResponse fr = frequencyResponse(ir, fs);
  if (smoothFrac > 0.0) fr = smoothFractionalOctave(fr, smoothFrac);

  const size_t n = std::min(points, cap);
  const FreqResponse grid = resampleLog(fr, fMin, fMax, n);
  for (size_t i = 0; i < grid.freqHz.size(); ++i) {
    freqOut[i] = grid.freqHz[i];
    magOut[i] = grid.magDb[i];
  }
  return grid.freqHz.size();
}

size_t rew_fit_peq_flat(const double* freq, const double* mag, size_t n, double fs,
                        double fMin, double fMax, int maxBands, double* freqOut,
                        double* gainOut, double* qOut) {
  if (!freq || !mag || !freqOut || !gainOut || !qOut) return 0;
  FreqResponse measured;
  measured.freqHz.assign(freq, freq + n);
  measured.magDb.assign(mag, mag + n);

  PeqConstraints c;
  c.fs = fs;
  c.fMin = fMin;
  c.fMax = fMax;
  c.maxBands = maxBands;

  const PeqFitResult res = fitPeq(measured, flatTarget(measured), c);
  for (size_t i = 0; i < res.bands.size(); ++i) {
    freqOut[i] = res.bands[i].freqHz;
    gainOut[i] = res.bands[i].gainDb;
    qOut[i] = res.bands[i].q;
  }
  return res.bands.size();
}

}  // extern "C"
