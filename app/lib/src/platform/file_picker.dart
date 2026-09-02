// Thin wrapper over the native document picker (see MainActivity's
// `rew_mobile/files` channel). Kept separate from the audio backend because it is
// a UI concern, not part of the measurement path.
import 'package:flutter/services.dart';

class NativeFilePicker {
  static const _channel = MethodChannel('rew_mobile/files');

  /// Opens the system document picker and returns the chosen file's text.
  /// Returns null when the user cancels.
  ///
  /// Throws [MissingPluginException] on platforms where the picker isn't
  /// implemented (desktop, tests) — callers should fall back to pasting.
  static Future<String?> pickTextFile() =>
      _channel.invokeMethod<String>('pickTextFile');
}
