#pragma once
#include <complex>
#include <cstddef>
#include <vector>

namespace rewcore {

using Complex = std::complex<double>;

// Smallest power of two >= n.
std::size_t nextPow2(std::size_t n);

// In-place radix-2 Cooley-Tukey FFT. data.size() must be a power of two.
// inverse == false -> forward transform; inverse == true -> inverse (scaled by 1/N).
void fft(std::vector<Complex>& data, bool inverse);

// Convenience: forward FFT of a real signal, zero-padded to `fftSize`
// (which must be a power of two and >= signal.size()).
std::vector<Complex> rfft(const std::vector<double>& signal, std::size_t fftSize);

// Inverse FFT returning the real part. spectrum.size() must be a power of two.
std::vector<double> irfft(std::vector<Complex> spectrum);

}  // namespace rewcore
