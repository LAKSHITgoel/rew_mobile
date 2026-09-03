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

  /// Directory the share sheet can read from (app-specific external storage,
  /// so no storage permission is needed).
  static Future<String?> exportDirectory() async {
    try {
      return await _channel.invokeMethod<String>('exportDir');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens the system "save as" dialog with [suggestedName] so the user picks
  /// the folder and file name. Returns false if they cancel.
  static Future<bool> saveFileAs(String path,
      {required String suggestedName, String mime = '*/*'}) async {
    final ok = await _channel.invokeMethod<bool>('saveFileAs',
        {'path': path, 'name': suggestedName, 'mime': mime});
    return ok ?? false;
  }

  /// Hands files to the system share sheet.
  static Future<void> shareFiles(List<String> paths, {String mime = '*/*'}) =>
      _channel.invokeMethod<void>('shareFiles', {'paths': paths, 'mime': mime});

  /// Directory for saved tunes. Returns null where unimplemented, in which case
  /// the caller should fall back to in-memory storage.
  static Future<String?> appDirectory() async {
    try {
      return await _channel.invokeMethod<String>('appDir');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
