#include "rewcore/fft.hpp"

#include <cmath>

namespace rewcore {

std::size_t nextPow2(std::size_t n) {
  std::size_t p = 1;
  while (p < n) p <<= 1;
  return p;
}

void fft(std::vector<Complex>& a, bool inverse) {
  const std::size_t n = a.size();
  if (n <= 1) return;

  // Bit-reversal permutation.
  for (std::size_t i = 1, j = 0; i < n; ++i) {
    std::size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }

  const double sign = inverse ? 1.0 : -1.0;
  for (std::size_t len = 2; len <= n; len <<= 1) {
    const double ang = sign * 2.0 * M_PI / static_cast<double>(len);
    const Complex wlen(std::cos(ang), std::sin(ang));
    for (std::size_t i = 0; i < n; i += len) {
      Complex w(1.0, 0.0);
      for (std::size_t k = 0; k < len / 2; ++k) {
        const Complex u = a[i + k];
        const Complex v = a[i + k + len / 2] * w;
        a[i + k] = u + v;
        a[i + k + len / 2] = u - v;
        w *= wlen;
      }
    }
  }

  if (inverse) {
    for (auto& x : a) x /= static_cast<double>(n);
  }
}

std::vector<Complex> rfft(const std::vector<double>& signal, std::size_t fftSize) {
  std::vector<Complex> buf(fftSize, Complex(0.0, 0.0));
  const std::size_t m = std::min(signal.size(), fftSize);
  for (std::size_t i = 0; i < m; ++i) buf[i] = Complex(signal[i], 0.0);
  fft(buf, /*inverse=*/false);
  return buf;
}

std::vector<double> irfft(std::vector<Complex> spectrum) {
  fft(spectrum, /*inverse=*/true);
  std::vector<double> out(spectrum.size());
  for (std::size_t i = 0; i < spectrum.size(); ++i) out[i] = spectrum[i].real();
  return out;
}

}  // namespace rewcore
