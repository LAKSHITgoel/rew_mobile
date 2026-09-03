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

/// One input-level reading from the microphone.
class MicLevel {
  const MicLevel({required this.rmsDb, required this.peakDb});
  final double rmsDb;
  final double peakDb;

  /// Roughly "is the mic hearing anything at all". Room tone on a UMIK-1 sits
  /// well below this; speech or a tap sits well above.
  bool get hasSignal => rmsDb > -60;
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

  /// Live input level, for confirming the mic is connected AND hearing sound.
  /// Only produces values between [startInputLevel] and [stopInputLevel].
  Stream<MicLevel> get inputLevels;
  Future<void> startInputLevel();
  Future<void> stopInputLevel();

  /// Loop [samples] out as media until [stopTone] — the centring signal for
  /// manual time alignment.
  Future<void> startTone({required Float64List samples, required double fs});
  Future<void> stopTone();

  Future<void> dispose();
}
