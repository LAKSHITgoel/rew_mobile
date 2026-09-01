#include "rewcore/wav.hpp"

#include <cstdint>
#include <cstring>
#include <fstream>

namespace rewcore {

namespace {

void putU32(std::ofstream& o, uint32_t v) {
  char b[4] = {char(v & 0xff), char((v >> 8) & 0xff), char((v >> 16) & 0xff),
               char((v >> 24) & 0xff)};
  o.write(b, 4);
}
void putU16(std::ofstream& o, uint16_t v) {
  char b[2] = {char(v & 0xff), char((v >> 8) & 0xff)};
  o.write(b, 2);
}

uint32_t getU32(const unsigned char* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}
uint16_t getU16(const unsigned char* p) {
  return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}

}  // namespace

bool writeWavMonoFloat(const std::string& path, const AudioBuffer& buf) {
  std::ofstream o(path, std::ios::binary);
  if (!o) return false;

  const uint32_t sr = static_cast<uint32_t>(buf.sampleRate);
  const uint16_t channels = 1;
  const uint16_t bits = 32;
  const uint32_t dataBytes = static_cast<uint32_t>(buf.samples.size() * 4);
  const uint32_t byteRate = sr * channels * (bits / 8);

  o.write("RIFF", 4);
  putU32(o, 36 + dataBytes);
  o.write("WAVE", 4);

  o.write("fmt ", 4);
  putU32(o, 16);
  putU16(o, 3);  // IEEE float
  putU16(o, channels);
  putU32(o, sr);
  putU32(o, byteRate);
  putU16(o, channels * (bits / 8));
  putU16(o, bits);

  o.write("data", 4);
  putU32(o, dataBytes);
  for (double s : buf.samples) {
    float f = static_cast<float>(s);
    o.write(reinterpret_cast<const char*>(&f), 4);
  }
  return static_cast<bool>(o);
}

bool readWavMono(const std::string& path, AudioBuffer& out) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
  if (bytes.size() < 44) return false;
  if (std::memcmp(bytes.data(), "RIFF", 4) != 0 ||
      std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
    return false;
  }

  uint16_t format = 1, channels = 1, bits = 16;
  uint32_t sampleRate = 48000;
  std::size_t dataOffset = 0, dataSize = 0;

  std::size_t pos = 12;
  while (pos + 8 <= bytes.size()) {
    const unsigned char* chunk = bytes.data() + pos;
    const uint32_t size = getU32(chunk + 4);
    if (std::memcmp(chunk, "fmt ", 4) == 0 && pos + 8 + 16 <= bytes.size()) {
      const unsigned char* f = chunk + 8;
      format = getU16(f);
      channels = getU16(f + 2);
      sampleRate = getU32(f + 4);
      bits = getU16(f + 14);
    } else if (std::memcmp(chunk, "data", 4) == 0) {
      dataOffset = pos + 8;
      dataSize = size;
      break;
    }
    pos += 8 + size + (size & 1);  // chunks are word-aligned
  }
  if (dataOffset == 0 || channels == 0) return false;
  dataSize = std::min<std::size_t>(dataSize, bytes.size() - dataOffset);

  out.sampleRate = sampleRate;
  out.samples.clear();

  const std::size_t bytesPerSample = bits / 8;
  const std::size_t frameBytes = bytesPerSample * channels;
  if (frameBytes == 0) return false;
  const std::size_t frames = dataSize / frameBytes;
  out.samples.reserve(frames);

  const unsigned char* d = bytes.data() + dataOffset;
  for (std::size_t fr = 0; fr < frames; ++fr) {
    double acc = 0.0;
    for (uint16_t ch = 0; ch < channels; ++ch) {
      const unsigned char* s = d + (fr * channels + ch) * bytesPerSample;
      double v = 0.0;
      if (format == 3 && bits == 32) {
        float f;
        std::memcpy(&f, s, 4);
        v = f;
      } else if (format == 1 && bits == 16) {
        int16_t i = static_cast<int16_t>(getU16(s));
        v = i / 32768.0;
      } else if (format == 1 && bits == 32) {
        int32_t i = static_cast<int32_t>(getU32(s));
        v = i / 2147483648.0;
      } else {
        return false;  // unsupported
      }
      acc += v;
    }
    out.samples.push_back(acc / channels);
  }
  return true;
}

}  // namespace rewcore
