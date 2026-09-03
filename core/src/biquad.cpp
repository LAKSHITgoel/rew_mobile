#include "rewcore/biquad.hpp"

#include <cmath>
#include <complex>

namespace rewcore {

double Biquad::magnitude(double f, double fs) const {
  const double w = 2.0 * M_PI * f / fs;
  const std::complex<double> z1 = std::polar(1.0, -w);
  const std::complex<double> z2 = std::polar(1.0, -2.0 * w);
  const std::complex<double> num = b0 + b1 * z1 + b2 * z2;
  const std::complex<double> den = 1.0 + a1 * z1 + a2 * z2;
  return std::abs(num / den);
}

double Biquad::magnitudeDb(double f, double fs) const {
  return 20.0 * std::log10(magnitude(f, fs));
}

Biquad makePeaking(double f0, double fs, double gainDb, double q) {
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * M_PI * f0 / fs;
  const double cw = std::cos(w0);
  const double sw = std::sin(w0);
  const double alpha = sw / (2.0 * q);

  const double a0 = 1.0 + alpha / A;
  Biquad bq;
  bq.b0 = (1.0 + alpha * A) / a0;
  bq.b1 = (-2.0 * cw) / a0;
  bq.b2 = (1.0 - alpha * A) / a0;
  bq.a1 = (-2.0 * cw) / a0;
  bq.a2 = (1.0 - alpha / A) / a0;
  return bq;
}

Biquad makeLowPass(double f0, double fs, double q) {
  const double w0 = 2.0 * M_PI * f0 / fs;
  const double cw = std::cos(w0);
  const double alpha = std::sin(w0) / (2.0 * q);
  const double a0 = 1.0 + alpha;
  Biquad bq;
  bq.b0 = ((1.0 - cw) / 2.0) / a0;
  bq.b1 = (1.0 - cw) / a0;
  bq.b2 = ((1.0 - cw) / 2.0) / a0;
  bq.a1 = (-2.0 * cw) / a0;
  bq.a2 = (1.0 - alpha) / a0;
  return bq;
}

Biquad makeHighPass(double f0, double fs, double q) {
  const double w0 = 2.0 * M_PI * f0 / fs;
  const double cw = std::cos(w0);
  const double alpha = std::sin(w0) / (2.0 * q);
  const double a0 = 1.0 + alpha;
  Biquad bq;
  bq.b0 = ((1.0 + cw) / 2.0) / a0;
  bq.b1 = -(1.0 + cw) / a0;
  bq.b2 = ((1.0 + cw) / 2.0) / a0;
  bq.a1 = (-2.0 * cw) / a0;
  bq.a2 = (1.0 - alpha) / a0;
  return bq;
}

Biquad makeLowShelf(double f0, double fs, double gainDb, double q) {
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * M_PI * f0 / fs;
  const double cw = std::cos(w0);
  const double sw = std::sin(w0);
  const double alpha = sw / (2.0 * q);
  const double twoSqrtAalpha = 2.0 * std::sqrt(A) * alpha;

  const double a0 = (A + 1.0) + (A - 1.0) * cw + twoSqrtAalpha;
  Biquad bq;
  bq.b0 = A * ((A + 1.0) - (A - 1.0) * cw + twoSqrtAalpha) / a0;
  bq.b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw) / a0;
  bq.b2 = A * ((A + 1.0) - (A - 1.0) * cw - twoSqrtAalpha) / a0;
  bq.a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw) / a0;
  bq.a2 = ((A + 1.0) + (A - 1.0) * cw - twoSqrtAalpha) / a0;
  return bq;
}

Biquad makeHighShelf(double f0, double fs, double gainDb, double q) {
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * M_PI * f0 / fs;
  const double cw = std::cos(w0);
  const double sw = std::sin(w0);
  const double alpha = sw / (2.0 * q);
  const double twoSqrtAalpha = 2.0 * std::sqrt(A) * alpha;

  const double a0 = (A + 1.0) - (A - 1.0) * cw + twoSqrtAalpha;
  Biquad bq;
  bq.b0 = A * ((A + 1.0) + (A - 1.0) * cw + twoSqrtAalpha) / a0;
  bq.b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw) / a0;
  bq.b2 = A * ((A + 1.0) + (A - 1.0) * cw - twoSqrtAalpha) / a0;
  bq.a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw) / a0;
  bq.a2 = ((A + 1.0) - (A - 1.0) * cw - twoSqrtAalpha) / a0;
  return bq;
}

double cascadeMagnitudeDb(const std::vector<PeqBand>& bands, double f, double fs) {
  double sum = 0.0;
  for (const auto& b : bands) {
    sum += makePeaking(b.freqHz, fs, b.gainDb, b.q).magnitudeDb(f, fs);
  }
  return sum;
}

}  // namespace rewcore
