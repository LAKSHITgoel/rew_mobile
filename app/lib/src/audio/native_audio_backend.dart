// Real-hardware AudioBackend: talks to the platform audio/USB plugins over a
// MethodChannel. The native side (android/native, ios/native) owns UMIK-1 capture
// and routing the sweep out to the OEM head unit. Implemented against the channel
// contract; requires the native plugins to be present (validate on real hardware).
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'audio_backend.dart';

/// Decodes a float32 little-endian sample block from the platform channel.
///
/// Read byte by byte through a ByteData view rather than with asFloat32List.
/// The Uint8List a MethodChannel hands back is a *view* into a larger buffer at
/// an arbitrary offset — 53 bytes in, on the device — and a typed-data view
/// must start on a 4-byte boundary, so the direct cast throws. Going through
/// ByteData also makes the endianness explicit instead of inheriting the host's.
Float64List? decodeSampleBlock(Object? raw) {
  if (raw is! Uint8List || raw.lengthInBytes < 4) return null;
  final view = ByteData.view(raw.buffer, raw.offsetInBytes, raw.lengthInBytes);
  final n = raw.lengthInBytes ~/ 4;
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = view.getFloat32(i * 4, Endian.little);
  }
  return out;
}

class NativeAudioBackend implements AudioBackend {
  static const _channel = MethodChannel('rew_mobile/audio');
  static const _levelChannel = EventChannel('rew_mobile/audio_levels');

  Stream<MicLevel>? _levels;

  @override
  Stream<MicLevel> get inputLevels =>
      _levels ??= _levelChannel.receiveBroadcastStream().map((event) {
        final m = (event as Map).cast<String, dynamic>();
        final samples = decodeSampleBlock(m['samples']);
        return MicLevel(
          rmsDb: (m['rmsDb'] as num).toDouble(),
          peakDb: (m['peakDb'] as num).toDouble(),
          samples: samples,
        );
      });

  @override
  Future<void> startInputLevel({bool withSamples = false}) async {
    await _channel
        .invokeMethod<void>('startInputLevel', {'withSamples': withSamples});
  }

  @override
  Future<void> stopInputLevel() async {
    await _channel.invokeMethod<void>('stopInputLevel');
  }

  @override
  Future<void> startTone(
      {required Float64List samples, required double fs}) async {
    await _channel.invokeMethod<void>('startTone', {
      'samples': samples.buffer.asUint8List(),
      'fs': fs,
    });
  }

  @override
  Future<void> stopTone() async {
    await _channel.invokeMethod<void>('stopTone');
  }

  @override
  Future<MicInfo> micStatus() async {
    // Never allowed to throw or to hang.
    //
    // This is called first thing when Measure is tapped, and it used to be able
    // to do both: it enumerates audio devices on the platform thread, which can
    // fail or stall while Android is rebuilding its device list — exactly what
    // happens when a USB microphone is plugged in, unplugged, or the phone
    // switches audio route in a car. An exception here propagated out of the
    // tap handler with nothing to catch it, so the measurement silently never
    // started: no spinner, no error, a button that appeared dead.
    try {
      final res = await _channel
          .invokeMapMethod<String, dynamic>('micStatus')
          .timeout(const Duration(seconds: 3));
      return MicInfo(
        connected: (res?['connected'] as bool?) ?? false,
        name: res?['name'] as String?,
      );
    } catch (e) {
      return MicInfo(connected: false, probeError: '$e');
    }
  }

  @override
  Future<Float64List> playSweepAndCapture({
    required Float64List sweep,
    required double fs,
  }) async {
    // Send the stimulus as raw float64 bytes; receive the recording the same way.
    final result = await _channel.invokeMethod<Float64List>(
      'playSweepAndCapture',
      {
        'sweep': sweep.buffer.asUint8List(),
        'fs': fs,
      },
    );
    if (result == null) {
      throw StateError('native capture returned no data');
    }
    return result;
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod<void>('dispose');
  }
}
