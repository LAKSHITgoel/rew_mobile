// Dependency container assembled at startup and passed down the widget tree.
import 'audio/audio_backend.dart';
import 'ffi/rewcore.dart';
import 'models/mic_calibration.dart';
import 'services/journal_store.dart';
import 'services/project_store.dart';

class AppServices {
  AppServices({
    required this.core,
    required this.audio,
    required this.store,
    required this.journal,
  });

  final Rewcore core;
  final AudioBackend audio;
  final ProjectStore store;

  /// What the app recommended, and whether it worked. The evidence any change
  /// to the heuristics has to be argued from.
  final JournalStore journal;

  /// The UMIK-1 calibration, once loaded. Held here rather than inside one tune
  /// because it belongs to the microphone, not to a car — the analyser needs it
  /// as much as a swept measurement does.
  MicCalibration? calibration;
}
