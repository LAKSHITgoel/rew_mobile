#pragma once
#include <string>
#include <vector>

#include "rewcore/dsp.hpp"

namespace rewcore {

// A parsed UMIK-1 calibration file: frequency/gain pairs plus optional sensitivity.
struct MicCalibration {
  std::vector<double> freqHz;
  std::vector<double> gainDb;
  double sensitivityDbFs = 0.0;  // "Sens Factor" from the header, if present
  bool hasSensitivity = false;
};

// Parse a miniDSP-style calibration .txt. Lines are "freq gain [phase]"; lines that
// begin with '*', '#', or ';' are comments, except a header line containing
// "Sens Factor =<x>dB" which sets the sensitivity. Whitespace/comma separated.
MicCalibration parseMicCalibration(const std::string& text);

// Apply a mic calibration to a measured response by subtracting the mic's own
// (interpolated) frequency response, so the result reflects the loudspeaker/room,
// not the microphone. Frequencies outside the cal file's range are left unchanged.
FreqResponse applyMicCalibration(const FreqResponse& measured,
                                 const MicCalibration& cal);

}  // namespace rewcore
