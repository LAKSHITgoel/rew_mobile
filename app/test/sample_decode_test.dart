// The platform-channel decode path, which no mock-backed test can reach: the
// mock hands Dart objects straight over, while the device hands over bytes.
// That gap hid a crash that only appeared on the phone.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/audio/native_audio_backend.dart';

Uint8List _encode(List<double> values, {int leadingPadBytes = 0}) {
  final buf = Uint8List(leadingPadBytes + values.length * 4);
  final view = ByteData.view(buf.buffer);
  for (var i = 0; i < values.length; i++) {
    view.setFloat32(leadingPadBytes + i * 4, values[i], Endian.little);
  }
  // A view starting partway into a larger buffer, exactly as a MethodChannel
  // delivers it.
  return Uint8List.view(buf.buffer, leadingPadBytes, values.length * 4);
}

void main() {
  test('decodes float32 little-endian samples', () {
    final out = decodeSampleBlock(_encode([0, 0.5, -0.25, 1]));
    expect(out, isNotNull);
    expect(out!.length, 4);
    expect(out[0], closeTo(0, 1e-6));
    expect(out[1], closeTo(0.5, 1e-6));
    expect(out[2], closeTo(-0.25, 1e-6));
    expect(out[3], closeTo(1, 1e-6));
  });

  test('decodes a block that does not start on a 4-byte boundary', () {
    // This is the real case. The device delivered a view at offset 53, and
    // casting the underlying buffer to Float32List threw
    // "Offset (53) must be a multiple of BYTES_PER_ELEMENT (4)".
    for (final pad in [1, 2, 3, 53]) {
      final out = decodeSampleBlock(_encode([0.25, -0.75], leadingPadBytes: pad));
      expect(out, isNotNull, reason: 'failed at offset $pad');
      expect(out![0], closeTo(0.25, 1e-6), reason: 'wrong value at offset $pad');
      expect(out[1], closeTo(-0.75, 1e-6));
    }
  });

  test('anything that is not a usable block decodes to null', () {
    expect(decodeSampleBlock(null), isNull);
    expect(decodeSampleBlock('not bytes'), isNull);
    expect(decodeSampleBlock(Uint8List(0)), isNull);
    expect(decodeSampleBlock(Uint8List(2)), isNull); // shorter than one sample
  });
}
