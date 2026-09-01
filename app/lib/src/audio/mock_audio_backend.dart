// A hardware-free AudioBackend: instead of playing through a car and capturing a
// mic, it passes the sweep through a synthetic "car + DSP + room" response (a few
// biquads) plus a little latency and noise. This lets the entire app flow —
// measure, auto-EQ, verify — be exercised end-to-end with no mic or vehicle, and
// produces a realistically bumpy response for the EQ to correct.
import 'dart:math';
import 'dart:typed_data';

import 'audio_backend.dart';

class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
  final double b0, b1, b2, a1, a2;

  static _Biquad peaking(double f0, double fs, double gainDb, double q) {
    final a = pow(10, gainDb / 40).toDouble();
    final w0 = 2 * pi * f0 / fs;
    final cw = cos(w0), sw = sin(w0);
    final alpha = sw / (2 * q);
    final a0 = 1 + alpha / a;
    return _Biquad(
      (1 + alpha * a) / a0,
      (-2 * cw) / a0,
      (1 - alpha * a) / a0,
      (-2 * cw) / a0,
      (1 - alpha / a) / a0,
    );
  }

  Float64List apply(Float64List x) {
    final y = Float64List(x.length);
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (var n = 0; n < x.length; n++) {
      final o = b0 * x[n] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x[n];
      y2 = y1;
      y1 = o;
      y[n] = o;
    }
    return y;
  }
}

class MockAudioBackend implements AudioBackend {
  MockAudioBackend({this.seed = 1});
  final int seed;

  @override
  Future<MicInfo> micStatus() async =>
      const MicInfo(connected: true, name: 'UMIK-1 (mock)');

  @override
  Future<Float64List> playSweepAndCapture({
    required Float64List sweep,
    required double fs,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // A synthetic in-car response: bass hump, presence dip, treble roll-off.
    var y = sweep;
    y = _Biquad.peaking(65, fs, 8, 0.9).apply(y);
    y = _Biquad.peaking(2800, fs, -6, 2.0).apply(y);
    y = _Biquad.peaking(9000, fs, -4, 0.8).apply(y);

    // Emulate wireless latency (leading silence) + capture tail.
    const latencySamples = 2400; // ~50 ms at 48 kHz
    final rnd = Random(seed);
    final out = Float64List(latencySamples + y.length + 4096);
    for (var i = 0; i < y.length; i++) {
      out[latencySamples + i] = y[i];
    }
    // A touch of measurement noise.
    for (var i = 0; i < out.length; i++) {
      out[i] += (rnd.nextDouble() - 0.5) * 1e-4;
    }
    return out;
  }

  @override
  Future<void> dispose() async {}
}
