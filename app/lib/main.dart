import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app_services.dart';
import 'src/audio/audio_backend.dart';
import 'src/audio/mock_audio_backend.dart';
import 'src/audio/native_audio_backend.dart';
import 'src/ffi/rewcore.dart';
import 'src/services/project_store.dart';
import 'src/ui/home_screen.dart';

/// Set true to force the hardware-free mock backend (synthesizes a measurement),
/// e.g. for demos on desktop or an emulator with no mic/car. When false, the app
/// uses the native audio/USB backend on real devices.
const bool kUseMockAudio =
    bool.fromEnvironment('USE_MOCK_AUDIO', defaultValue: kDebugMode);

void main() {
  runApp(const RewApp());
}

class RewApp extends StatelessWidget {
  const RewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car Audio Tuner',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const _Bootstrap(),
    );
  }
}

/// Builds the service container, surfacing a clear message if the native rewcore
/// library isn't linked (the app's DSP runs entirely in that library).
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context) {
    AppServices services;
    try {
      final AudioBackend audio =
          kUseMockAudio ? MockAudioBackend() : NativeAudioBackend();
      services = AppServices(
        core: Rewcore.open(),
        audio: audio,
        store: MemoryProjectStore(),
      );
    } catch (e) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load the native rewcore library.\n\n'
              'Bootstrap the platform folders and link the FFI plugin '
              '(see app/README.md).\n\n$e',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return HomeScreen(services: services);
  }
}
