// Dependency container assembled at startup and passed down the widget tree.
import 'audio/audio_backend.dart';
import 'ffi/rewcore.dart';
import 'services/project_store.dart';

class AppServices {
  AppServices({required this.core, required this.audio, required this.store});

  final Rewcore core;
  final AudioBackend audio;
  final ProjectStore store;
}
