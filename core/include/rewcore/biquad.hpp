#pragma once
#include <vector>

namespace rewcore {

// A single second-order IIR section (normalized so a0 == 1).
// Coefficient conventions follow the Audio-EQ Cookbook (RBJ).
struct Biquad {
  double b0 = 1.0, b1 = 0.0, b2 = 0.0;
  double a1 = 0.0, a2 = 0.0;  // a0 is implicitly 1

  // Complex magnitude (linear) of this section at frequency `f` Hz, sample rate `fs`.
  double magnitude(double f, double fs) const;
  // Magnitude expressed in dB.
  double magnitudeDb(double f, double fs) const;
};

// Parametric ("peaking") EQ band — the kind the Alpine PEQ exposes.
Biquad makePeaking(double f0, double fs, double gainDb, double q);

// 2nd-order low/high pass (RBJ). Used to band-limit test signals.
Biquad makeLowPass(double f0, double fs, double q = 0.70710678);
Biquad makeHighPass(double f0, double fs, double q = 0.70710678);

// Low/high shelf.
Biquad makeLowShelf(double f0, double fs, double gainDb, double q);
Biquad makeHighShelf(double f0, double fs, double gainDb, double q);

// A named PEQ band as it would be entered into the DSP app.
struct PeqBand {
  double freqHz;
  double gainDb;
  double q;
};

// Combined magnitude (dB) of a cascade of PEQ bands at frequency `f`.
double cascadeMagnitudeDb(const std::vector<PeqBand>& bands, double f, double fs);

}  // namespace rewcore
