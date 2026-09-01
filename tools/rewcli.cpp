// rewcli — desktop command-line front end for rewcore.
//
// Lets you exercise the whole measurement/tuning pipeline from WAV files, with no
// phone or mic, on any desktop or homeserver. Handy for cross-checking rewcore against
// REW's own exports before the mobile app exists.
//
//   rewcli sweep   out.wav [--fs 48000 --f1 20 --f2 20000 --dur 3]
//   rewcli measure --emitted sweep.wav --recorded rec.wav [--cal mic.txt]
//                  [--smooth 24] [--fmin 20 --fmax 20000 --points 96] [--csv fr.csv]
//   rewcli eq      --emitted sweep.wav --recorded rec.wav [--cal mic.txt]
//                  [--bands 10] [--target flat|tilt] [--slope -1.0]
//   rewcli xover   --fc 2500 [--slope lr24|lr48|bw12] [--fmin 200 --fmax 20000]
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "rewcore/calibration.hpp"
#include "rewcore/crossover.hpp"
#include "rewcore/dsp.hpp"
#include "rewcore/peq.hpp"
#include "rewcore/wav.hpp"

using namespace rewcore;

namespace {

std::map<std::string, std::string> parseFlags(int argc, char** argv, int start) {
  std::map<std::string, std::string> flags;
  for (int i = start; i < argc; ++i) {
    std::string a = argv[i];
    if (a.rfind("--", 0) == 0 && i + 1 < argc) {
      flags[a.substr(2)] = argv[++i];
    }
  }
  return flags;
}

double flagD(const std::map<std::string, std::string>& f, const std::string& k,
            double def) {
  auto it = f.find(k);
  return it == f.end() ? def : std::atof(it->second.c_str());
}
int flagI(const std::map<std::string, std::string>& f, const std::string& k, int def) {
  auto it = f.find(k);
  return it == f.end() ? def : std::atoi(it->second.c_str());
}
std::string flagS(const std::map<std::string, std::string>& f, const std::string& k,
                  const std::string& def) {
  auto it = f.find(k);
  return it == f.end() ? def : it->second;
}

Slope parseSlope(const std::string& s) {
  if (s == "bw12") return Slope::Butterworth12;
  if (s == "lr48") return Slope::LinkwitzRiley48;
  return Slope::LinkwitzRiley24;
}

// Load an emitted+recorded pair and produce a smoothed, log-gridded, optionally
// mic-calibrated frequency response.
FreqResponse measureFromFiles(const std::map<std::string, std::string>& f, bool& ok) {
  ok = false;
  AudioBuffer emitted, recorded;
  if (!readWavMono(flagS(f, "emitted", ""), emitted)) {
    std::fprintf(stderr, "error: cannot read --emitted WAV\n");
    return {};
  }
  if (!readWavMono(flagS(f, "recorded", ""), recorded)) {
    std::fprintf(stderr, "error: cannot read --recorded WAV\n");
    return {};
  }
  const double fs = emitted.sampleRate;
  const std::vector<double> ir = deconvolve(emitted.samples, recorded.samples);
  FreqResponse fr = frequencyResponse(ir, fs);

  const double smooth = flagD(f, "smooth", 24.0);
  if (smooth > 0) fr = smoothFractionalOctave(fr, smooth);

  const std::string calPath = flagS(f, "cal", "");
  if (!calPath.empty()) {
    std::ifstream cf(calPath);
    if (cf) {
      std::string txt((std::istreambuf_iterator<char>(cf)),
                      std::istreambuf_iterator<char>());
      fr = applyMicCalibration(fr, parseMicCalibration(txt));
    } else {
      std::fprintf(stderr, "warning: cannot read --cal file, skipping\n");
    }
  }

  fr = resampleLog(fr, flagD(f, "fmin", 20.0), flagD(f, "fmax", 20000.0),
                   flagI(f, "points", 96));
  ok = true;
  return fr;
}

int cmdSweep(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: rewcli sweep out.wav [--fs --f1 --f2 --dur]\n");
    return 2;
  }
  const std::string out = argv[2];
  auto f = parseFlags(argc, argv, 3);
  SweepSpec spec;
  spec.fs = flagD(f, "fs", 48000);
  spec.f1 = flagD(f, "f1", 20);
  spec.f2 = flagD(f, "f2", 20000);
  spec.durationSec = flagD(f, "dur", 3.0);

  AudioBuffer buf;
  buf.sampleRate = spec.fs;
  buf.samples = generateExpSweep(spec);
  if (!writeWavMonoFloat(out, buf)) {
    std::fprintf(stderr, "error: cannot write %s\n", out.c_str());
    return 1;
  }
  std::printf("wrote %s: %.2fs exp-sweep %.0f..%.0f Hz @ %.0f Hz (%zu samples)\n",
              out.c_str(), spec.durationSec, spec.f1, spec.f2, spec.fs,
              buf.samples.size());
  return 0;
}

int cmdMeasure(int argc, char** argv) {
  auto f = parseFlags(argc, argv, 2);
  bool ok = false;
  FreqResponse fr = measureFromFiles(f, ok);
  if (!ok) return 1;

  const std::string csv = flagS(f, "csv", "");
  if (!csv.empty()) {
    std::ofstream o(csv);
    o << "freq_hz,mag_db\n";
    for (std::size_t i = 0; i < fr.freqHz.size(); ++i)
      o << fr.freqHz[i] << "," << fr.magDb[i] << "\n";
    std::printf("wrote %s (%zu points)\n", csv.c_str(), fr.freqHz.size());
  } else {
    std::printf("  freq(Hz)   mag(dB)\n");
    for (std::size_t i = 0; i < fr.freqHz.size(); ++i)
      std::printf("%10.1f  %8.2f\n", fr.freqHz[i], fr.magDb[i]);
  }
  return 0;
}

int cmdEq(int argc, char** argv) {
  auto f = parseFlags(argc, argv, 2);
  bool ok = false;
  FreqResponse fr = measureFromFiles(f, ok);
  if (!ok) return 1;

  TargetCurve target;
  if (flagS(f, "target", "flat") == "tilt") {
    target = tiltTarget(fr, 1000.0, flagD(f, "slope", -1.0));
  } else {
    target = flatTarget(fr);
  }

  AudioBuffer emittedForFs;
  readWavMono(flagS(f, "emitted", ""), emittedForFs);

  PeqConstraints c;
  c.fs = emittedForFs.sampleRate;
  c.maxBands = flagI(f, "bands", 10);
  c.fMin = flagD(f, "fmin", 20.0);
  c.fMax = flagD(f, "fmax", 20000.0);

  const PeqFitResult res = fitPeq(fr, target, c);
  std::printf("Auto-EQ: %d bands, RMS error %.2f dB -> %.2f dB\n",
              static_cast<int>(res.bands.size()), res.initialErrorDb,
              res.finalErrorDb);
  std::printf("  #   freq(Hz)   gain(dB)   Q\n");
  for (std::size_t i = 0; i < res.bands.size(); ++i) {
    std::printf("  %-2zu  %8.1f  %+8.2f  %5.2f\n", i + 1, res.bands[i].freqHz,
                res.bands[i].gainDb, res.bands[i].q);
  }
  return 0;
}

int cmdXover(int argc, char** argv) {
  auto f = parseFlags(argc, argv, 2);
  const double fc = flagD(f, "fc", 2500);
  const Slope s = parseSlope(flagS(f, "slope", "lr24"));
  const SummationCheck sc = checkSummation(fc, s, s, flagD(f, "fmin", 200),
                                           flagD(f, "fmax", 20000));
  std::printf("Crossover %.0f Hz: max summation deviation %.3f dB\n", fc,
              sc.maxDeviationDb);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "rewcli — car-audio measurement CLI\n"
                 "commands: sweep | measure | eq | xover  (run a command for usage)\n");
    return 2;
  }
  const std::string cmd = argv[1];
  if (cmd == "sweep") return cmdSweep(argc, argv);
  if (cmd == "measure") return cmdMeasure(argc, argv);
  if (cmd == "eq") return cmdEq(argc, argv);
  if (cmd == "xover") return cmdXover(argc, argv);
  std::fprintf(stderr, "unknown command: %s\n", cmd.c_str());
  return 2;
}
