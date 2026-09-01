// Abstraction over the platform audio + USB layer. The rest of the app talks to
// this interface only; a mock implementation lets the whole app run with no mic
// or car, and the native implementation (MethodChannel to the platform plugins)
// swaps in on real hardware.
import 'dart:typed_data';

class MicInfo {
  const MicInfo({required this.connected, this.name});
  final bool connected;
  final String? name;
}

abstract class AudioBackend {
  /// Whether a UMIK-1 (or other USB mic) is currently attached.
  Future<MicInfo> micStatus();

  /// Play [sweep] out as media audio (routed to the OEM head unit over wireless
  /// CarPlay/Android Auto/Bluetooth) while capturing from the USB mic. Returns the
  /// captured recording as mono samples in [-1, 1]. The recording is normally
  /// longer than the sweep (pre/post silence + system latency); rewcore's
  /// deconvolution handles the offset.
  Future<Float64List> playSweepAndCapture({
    required Float64List sweep,
    required double fs,
  });

  Future<void> dispose();
}
