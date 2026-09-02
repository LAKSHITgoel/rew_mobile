#include "rewcore/calibration.hpp"

#include <algorithm>
#include <cctype>
#include <sstream>

namespace rewcore {

MicCalibration parseMicCalibration(const std::string& text) {
  MicCalibration cal;
  std::istringstream stream(text);
  std::string line;

  while (std::getline(stream, line)) {
    // Normalize commas to spaces so "freq,gain" and "freq gain" both parse.
    std::replace(line.begin(), line.end(), ',', ' ');

    // Trim leading whitespace.
    std::size_t start = line.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) continue;
    const std::string trimmed = line.substr(start);

    // miniDSP ships the real UMIK-1 file with a quoted header rather than a
    // comment marker, e.g.  "Sens Factor =-0.989dB, SERNO: 7165152"
    if (trimmed[0] == '*' || trimmed[0] == '#' || trimmed[0] == ';' ||
        trimmed[0] == '"') {
      // Look for the sensitivity header, e.g. "Sens Factor =-1.234dB".
      const std::size_t pos = trimmed.find("Sens Factor");
      if (pos != std::string::npos) {
        const std::size_t eq = trimmed.find('=', pos);
        if (eq != std::string::npos) {
          std::string num;
          for (std::size_t i = eq + 1; i < trimmed.size(); ++i) {
            const char ch = trimmed[i];
            if (std::isdigit(static_cast<unsigned char>(ch)) || ch == '-' ||
                ch == '+' || ch == '.') {
              num += ch;
            } else if (!num.empty()) {
              break;
            }
          }
          if (!num.empty()) {
            try {
              cal.sensitivityDbFs = std::stod(num);
              cal.hasSensitivity = true;
            } catch (...) {
            }
          }
        }
      }
      continue;
    }

    std::istringstream ls(trimmed);
    double f, g;
    if (ls >> f >> g) {
      cal.freqHz.push_back(f);
      cal.gainDb.push_back(g);
    }
  }
  return cal;
}

static double interpCalDb(const MicCalibration& cal, double f, bool& inRange) {
  inRange = false;
  if (cal.freqHz.size() < 2) return 0.0;
  if (f < cal.freqHz.front() || f > cal.freqHz.back()) return 0.0;
  inRange = true;
  const auto it = std::lower_bound(cal.freqHz.begin(), cal.freqHz.end(), f);
  if (it == cal.freqHz.begin()) return cal.gainDb.front();
  const std::size_t hi = static_cast<std::size_t>(it - cal.freqHz.begin());
  const std::size_t lo = hi - 1;
  const double t = (f - cal.freqHz[lo]) / (cal.freqHz[hi] - cal.freqHz[lo]);
  return cal.gainDb[lo] + t * (cal.gainDb[hi] - cal.gainDb[lo]);
}

FreqResponse applyMicCalibration(const FreqResponse& measured,
                                 const MicCalibration& cal) {
  FreqResponse out = measured;
  for (std::size_t i = 0; i < out.freqHz.size(); ++i) {
    bool inRange = false;
    const double micDb = interpCalDb(cal, out.freqHz[i], inRange);
    if (inRange) out.magDb[i] -= micDb;
  }
  return out;
}

}  // namespace rewcore
