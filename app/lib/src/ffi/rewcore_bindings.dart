// Low-level dart:ffi bindings to the rewcore C ABI (core/ffi/rewcore_ffi.h).
//
// These are written by hand to keep the mapping obvious; they can also be
// regenerated with `dart run ffigen` (see pubspec.yaml) once the native library
// is wired into the Flutter build. Keep the signatures in sync with the header.
import 'dart:ffi' as ffi;

// const char* rew_version(void);
typedef _RewVersionC = ffi.Pointer<ffi.Char> Function();
typedef RewVersionDart = ffi.Pointer<ffi.Char> Function();

// size_t rew_generate_sweep(double fs, f1, f2, durationSec, double* out, size_t cap);
typedef _RewGenerateSweepC = ffi.Size Function(
    ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewGenerateSweepDart = int Function(
    double, double, double, double, ffi.Pointer<ffi.Double>, int);

// size_t rew_measure_fr(emitted*, emittedLen, recorded*, recordedLen, fs,
//                       fMin, fMax, smoothFrac, points, freqOut*, magOut*, cap);
typedef _RewMeasureFrC = ffi.Size Function(
    ffi.Pointer<ffi.Double>, ffi.Size, ffi.Pointer<ffi.Double>, ffi.Size,
    ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Size,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewMeasureFrDart = int Function(
    ffi.Pointer<ffi.Double>, int, ffi.Pointer<ffi.Double>, int,
    double, double, double, double, int,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int);

// size_t rew_fit_peq_flat(freq*, mag*, n, fs, fMin, fMax, maxBands,
//                         freqOut*, gainOut*, qOut*);
typedef _RewFitPeqFlatC = ffi.Size Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size, ffi.Double,
    ffi.Double, ffi.Double, ffi.Int, ffi.Pointer<ffi.Double>,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);
typedef RewFitPeqFlatDart = int Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int, double,
    double, double, int, ffi.Pointer<ffi.Double>,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);

/// Resolved function pointers for the rewcore native library.
class RewcoreBindings {
  RewcoreBindings(ffi.DynamicLibrary lib)
      : rewVersion =
            lib.lookupFunction<_RewVersionC, RewVersionDart>('rew_version'),
        rewGenerateSweep = lib
            .lookupFunction<_RewGenerateSweepC, RewGenerateSweepDart>(
                'rew_generate_sweep'),
        rewMeasureFr = lib
            .lookupFunction<_RewMeasureFrC, RewMeasureFrDart>('rew_measure_fr'),
        rewFitPeqFlat = lib.lookupFunction<_RewFitPeqFlatC, RewFitPeqFlatDart>(
            'rew_fit_peq_flat');

  final RewVersionDart rewVersion;
  final RewGenerateSweepDart rewGenerateSweep;
  final RewMeasureFrDart rewMeasureFr;
  final RewFitPeqFlatDart rewFitPeqFlat;

  /// Opens the rewcore shared library for the current platform. The name matches
  /// what the `plugin_ffi` template links; adjust if the plugin is renamed.
  static ffi.DynamicLibrary open() {
    // Android/Linux: .so; iOS/macOS: symbols are in the process (statically
    // linked framework); Windows: .dll.
    return ffi.DynamicLibrary.executable();
  }
}
