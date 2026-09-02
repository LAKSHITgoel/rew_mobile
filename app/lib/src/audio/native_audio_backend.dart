// Real-hardware AudioBackend: talks to the platform audio/USB plugins over a
// MethodChannel. The native side (android/native, ios/native) owns UMIK-1 capture
// and routing the sweep out to the OEM head unit. Implemented against the channel
// contract; requires the native plugins to be present (validate on real hardware).
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'audio_backend.dart';

class NativeAudioBackend implements AudioBackend {
  static const _channel = MethodChannel('rew_mobile/audio');
  static const _levelChannel = EventChannel('rew_mobile/audio_levels');

  Stream<MicLevel>? _levels;

  @override
  Stream<MicLevel> get inputLevels =>
      _levels ??= _levelChannel.receiveBroadcastStream().map((event) {
        final m = (event as Map).cast<String, dynamic>();
        return MicLevel(
          rmsDb: (m['rmsDb'] as num).toDouble(),
          peakDb: (m['peakDb'] as num).toDouble(),
        );
      });

  @override
  Future<void> startInputLevel() async {
    await _channel.invokeMethod<void>('startInputLevel');
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
    final res = await _channel.invokeMapMethod<String, dynamic>('micStatus');
    return MicInfo(
      connected: (res?['connected'] as bool?) ?? false,
      name: res?['name'] as String?,
    );
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
