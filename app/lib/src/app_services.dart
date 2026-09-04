// Dependency container assembled at startup and passed down the widget tree.
import 'audio/audio_backend.dart';
import 'ffi/rewcore.dart';
import 'models/mic_calibration.dart';
import 'mcp/mcp_server.dart';
import 'services/calibration_store.dart';
import 'services/journal_store.dart';
import 'services/project_store.dart';

class AppServices {
  AppServices({
    required this.core,
    required this.audio,
    required this.store,
    required this.journal,
    required this.calibrationStore,
    required this.mcpTokenStore,
  });

  final Rewcore core;
  final AudioBackend audio;
  final ProjectStore store;

  /// What the app recommended, and whether it worked. The evidence any change
  /// to the heuristics has to be argued from.
  final JournalStore journal;

  final CalibrationStore calibrationStore;

  /// Kept across launches so the token pasted into an assistant's
  /// configuration keeps working, and is revoked deliberately rather than by
  /// accident.
  final McpTokenStore mcpTokenStore;

  /// The UMIK-1 calibration, once loaded. Held here rather than inside one tune
  /// because it belongs to the microphone, not to a car — every part of the app
  /// that measures needs it, not just the tuning wizard.
  MicCalibration? calibration;

  /// Which file it came from, for showing the user which microphone this is.
  String? calibrationName;
}
