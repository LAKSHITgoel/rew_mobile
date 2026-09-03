// Low-level dart:ffi bindings to the rewcore C ABI (core/ffi/rewcore_ffi.h).
//
// These are written by hand to keep the mapping obvious; they can also be
// regenerated with `dart run ffigen` (see pubspec.yaml) once the native library
// is wired into the Flutter build. Keep the signatures in sync with the header.
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

// const char* rew_version(void);
typedef _RewVersionC = ffi.Pointer<ffi.Char> Function();
typedef RewVersionDart = ffi.Pointer<ffi.Char> Function();

// size_t rew_generate_sweep(double fs, f1, f2, durationSec, double* out, size_t cap);
typedef _RewGenerateSweepC = ffi.Size Function(
    ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewGenerateSweepDart = int Function(
    double, double, double, double, ffi.Pointer<ffi.Double>, int);

// double rew_rms_dbfs(const double* samples, size_t n);
typedef _RewRmsDbfsC = ffi.Double Function(ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewRmsDbfsDart = double Function(ffi.Pointer<ffi.Double>, int);

// size_t rew_generate_noise(fs, durationSec, fLo, fHi, amplitude, seed, out*, cap);
typedef _RewGenerateNoiseC = ffi.Size Function(
    ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Double,
    ffi.UnsignedInt, ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewGenerateNoiseDart = int Function(
    double, double, double, double, double, int,
    ffi.Pointer<ffi.Double>, int);

// size_t rew_measure_fr(emitted*, emittedLen, recorded*, recordedLen, fs,
//                       fMin, fMax, smoothFrac, points,
//                       calFreq*, calGain*, calN, freqOut*, magOut*, cap);
typedef _RewMeasureFrC = ffi.Size Function(
    ffi.Pointer<ffi.Double>, ffi.Size, ffi.Pointer<ffi.Double>, ffi.Size,
    ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Size,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size,
    ffi.Int, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>,
    ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewMeasureFrDart = int Function(
    ffi.Pointer<ffi.Double>, int, ffi.Pointer<ffi.Double>, int,
    double, double, double, double, int,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int,
    int, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>,
    ffi.Pointer<ffi.Double>, int);

// size_t rew_fit_peq_flat(freq*, mag*, n, fs, fMin, fMax, maxBands,
//                         freqOut*, gainOut*, qOut*, errOut*);
typedef _RewFitPeqFlatC = ffi.Size Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size, ffi.Double,
    ffi.Double, ffi.Double, ffi.Int, ffi.Double, ffi.Pointer<ffi.Double>,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);
typedef RewFitPeqFlatDart = int Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int, double,
    double, double, int, double, ffi.Pointer<ffi.Double>,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);

// int rew_recommend_crossover(freq*, mag*, n, dropDb, hpOut*, lpOut*);
typedef _RewRecommendCrossoverC = ffi.Int Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size, ffi.Double,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);
typedef RewRecommendCrossoverDart = int Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int, double,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);

/// Resolved function pointers for the rewcore native library.
class RewcoreBindings {
  RewcoreBindings(ffi.DynamicLibrary lib)
      : rewVersion =
            lib.lookupFunction<_RewVersionC, RewVersionDart>('rew_version'),
        rewGenerateSweep = lib
            .lookupFunction<_RewGenerateSweepC, RewGenerateSweepDart>(
                'rew_generate_sweep'),
        rewRmsDbfs =
            lib.lookupFunction<_RewRmsDbfsC, RewRmsDbfsDart>('rew_rms_dbfs'),
        rewGenerateNoise =
            lib.lookupFunction<_RewGenerateNoiseC, RewGenerateNoiseDart>(
                'rew_generate_noise'),
        rewMeasureFr = lib
            .lookupFunction<_RewMeasureFrC, RewMeasureFrDart>('rew_measure_fr'),
        rewFitPeqFlat = lib.lookupFunction<_RewFitPeqFlatC, RewFitPeqFlatDart>(
            'rew_fit_peq_flat'),
        rewRecommendCrossover =
            lib.lookupFunction<_RewRecommendCrossoverC, RewRecommendCrossoverDart>(
                'rew_recommend_crossover');

  final RewVersionDart rewVersion;
  final RewGenerateSweepDart rewGenerateSweep;
  final RewGenerateNoiseDart rewGenerateNoise;
  final RewRmsDbfsDart rewRmsDbfs;
  final RewMeasureFrDart rewMeasureFr;
  final RewFitPeqFlatDart rewFitPeqFlat;
  final RewRecommendCrossoverDart rewRecommendCrossover;

  /// Opens the rewcore native library for the current platform. The library name
  /// matches the `rewcore_ffi` plugin (see packages/rewcore_ffi).
  /// [libraryPath], when given, is opened directly instead of resolving by
  /// platform. Tests use it to load a locally built dylib, since a plain
  /// `dart`/`flutter test` process has no rewcore symbols linked in.
  static ffi.DynamicLibrary open({String? libraryPath}) {
    if (libraryPath != null) return ffi.DynamicLibrary.open(libraryPath);
    if (Platform.isAndroid || Platform.isLinux) {
      return ffi.DynamicLibrary.open('librewcore_ffi.so');
    }
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('rewcore_ffi.dll');
    }
    // iOS/macOS: statically linked into the app, symbols are in the process.
    return ffi.DynamicLibrary.process();
  }
}
