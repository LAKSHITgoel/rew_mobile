#pragma once
#include <string>
#include <vector>

namespace rewcore {

// A mono audio buffer in [-1, 1] with its sample rate.
struct AudioBuffer {
  std::vector<double> samples;
  double sampleRate = 48000.0;
};

// Write a mono 32-bit float WAV. Returns false on I/O error.
bool writeWavMonoFloat(const std::string& path, const AudioBuffer& buf);

// Read a WAV (16-bit PCM or 32-bit float, mono or interleaved multi-channel) and
// downmix to mono. Returns false on I/O error or unsupported format.
bool readWavMono(const std::string& path, AudioBuffer& out);

}  // namespace rewcore
