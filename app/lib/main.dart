import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app_services.dart';
import 'src/audio/audio_backend.dart';
import 'src/audio/mock_audio_backend.dart';
import 'src/audio/native_audio_backend.dart';
import 'src/ffi/rewcore.dart';
import 'src/platform/file_picker.dart';
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
///
/// Async because the store needs a directory from the platform: tunes are
/// written to disk so they survive the app being closed.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<AppServices> _services = _build();

  Future<AppServices> _build() async {
    final AudioBackend audio =
        kUseMockAudio ? MockAudioBackend() : NativeAudioBackend();
    // Fall back to memory only where there is no writable app directory
    // (desktop/tests) — on a device, tunes must persist.
    final dir = await NativeFilePicker.appDirectory();
    final ProjectStore store = dir == null
        ? MemoryProjectStore()
        : FileProjectStore(Directory('$dir/tunes'));
    return AppServices(core: Rewcore.open(), audio: audio, store: store);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _services,
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not start.\n\nIf this mentions rewcore, the native '
                  'library is not linked — see app/README.md.\n\n${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return HomeScreen(services: snap.data!);
      },
    );
  }
}
