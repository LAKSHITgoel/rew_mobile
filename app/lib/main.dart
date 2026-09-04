import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app_services.dart';
import 'src/audio/audio_backend.dart';
import 'src/audio/mock_audio_backend.dart';
import 'src/audio/native_audio_backend.dart';
import 'src/ffi/rewcore.dart';
import 'src/platform/file_picker.dart';
import 'src/services/calibration_store.dart';
import 'src/services/journal_store.dart';
import 'src/services/project_store.dart';
import 'src/ui/home_screen.dart';

/// Set true to force the hardware-free mock backend (synthesizes a measurement),
/// e.g. for demos on desktop or an emulator with no mic/car:
///
///   flutter run --dart-define=USE_MOCK_AUDIO=true
///
/// It must default to FALSE in every build, debug included. This once defaulted
/// to [kDebugMode], which meant a debug build on a real phone quietly fabricated
/// its measurements: it played no sweep, never opened the mic, and still drew a
/// plausible curve and recommended EQ. For a measurement tool that is worse than
/// failing, so the mock is now opt-in only and says so on screen.
const bool kUseMockAudio = bool.fromEnvironment('USE_MOCK_AUDIO');

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
      // A simulated measurement must never be mistakable for a real one.
      builder: (context, child) {
        if (!kUseMockAudio) return child ?? const SizedBox.shrink();
        return Column(children: [
          const Material(
            color: Color(0xFFB3261E),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'SIMULATED AUDIO — no mic, no sweep, numbers are fake',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: child ?? const SizedBox.shrink()),
        ]);
      },
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
    // The journal lives beside the tunes; in memory only where there is
    // nowhere to write, which is the same rule the tunes follow.
    final JournalStore journal =
        dir == null ? MemoryJournalStore() : FileJournalStore(Directory(dir));

    final CalibrationStore calibrationStore = dir == null
        ? MemoryCalibrationStore()
        : FileCalibrationStore(Directory(dir));

    final services = AppServices(
      core: Rewcore.open(),
      audio: audio,
      store: store,
      journal: journal,
      calibrationStore: calibrationStore,
    );

    // Load it once, at startup, so every measurement the app makes is
    // calibrated — not only the ones taken after someone remembered to load a
    // file inside a tune.
    final stored = await calibrationStore.load();
    if (stored != null) {
      services.calibration = stored.calibration;
      services.calibrationName = stored.name;
    }
    return services;
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
