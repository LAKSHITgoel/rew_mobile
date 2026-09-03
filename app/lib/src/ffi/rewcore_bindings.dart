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


// size_t rew_fit_peq_flat(freq*, mag*, n, fs, fMin, fMax, maxBands,
//                         targetPercentile, maxCutDb, valid*,
//                         freqOut*, gainOut*, qOut*, errOut*);
// errOut receives THREE doubles: initial error, final error, suggested level trim.
/// Mirrors `rew_crossover_edge` / `rew_crossover_result` in
/// core/ffi/rewcore_ffi.h. Field order and types must match exactly.
final class RewCrossoverEdge extends ffi.Struct {
  @ffi.Int()
  external int present;
  @ffi.Int()
  external int reason;
  @ffi.Double()
  external double freqHz;
  @ffi.Double()
  external double recommendedHz;
  @ffi.Double()
  external double acousticSlopeDbPerOct;
  @ffi.Double()
  external double electricalSlopeDbPerOct;
  @ffi.Double()
  external double confidence;
}

final class RewCrossoverResult extends ffi.Struct {
  external RewCrossoverEdge highPass;
  external RewCrossoverEdge lowPass;
  @ffi.Double()
  external double passbandDb;
}

// size_t rew_crossover_result_size(void);
typedef _RewCrossoverResultSizeC = ffi.Size Function();
typedef RewCrossoverResultSizeDart = int Function();

/// Mirrors `rew_measure_request` in core/ffi/rewcore_ffi.h. Field order and
/// types must match exactly; see the note on [RewPeqRequest].
final class RewMeasureRequest extends ffi.Struct {
  external ffi.Pointer<ffi.Double> emitted;
  external ffi.Pointer<ffi.Double> recorded;
  external ffi.Pointer<ffi.Double> calFreq;
  external ffi.Pointer<ffi.Double> calGain;
  @ffi.Size()
  external int emittedLen;
  @ffi.Size()
  external int recordedLen;
  @ffi.Size()
  external int calN;
  @ffi.Size()
  external int points;

  @ffi.Double()
  external double fs;
  @ffi.Double()
  external double fMin;
  @ffi.Double()
  external double fMax;
  @ffi.Double()
  external double smoothFrac;
  @ffi.Double()
  external double analysisSmoothFrac;
  @ffi.Int()
  external int timeReferencePhase;
  @ffi.Int()
  external int reserved;

  external ffi.Pointer<ffi.Double> freqOut;
  external ffi.Pointer<ffi.Double> magOut;
  external ffi.Pointer<ffi.Double> magAnalysisOut;
  external ffi.Pointer<ffi.Double> phaseOut;
  @ffi.Size()
  external int cap;
}

// size_t rew_measure_fr(const rew_measure_request*);
typedef _RewMeasureFrC = ffi.Size Function(ffi.Pointer<RewMeasureRequest>);
typedef RewMeasureFrDart = int Function(ffi.Pointer<RewMeasureRequest>);

// size_t rew_measure_request_size(void);
typedef _RewMeasureRequestSizeC = ffi.Size Function();
typedef RewMeasureRequestSizeDart = int Function();

/// Mirrors `rew_peq_request` in core/ffi/rewcore_ffi.h. **Field order and types
/// must match that struct exactly** — Dart lays this out with the platform C
/// ABI, so a reordering here is silent corruption, not a compile error. The
/// `reserved` int is the explicit padding the C side declares for the same
/// reason.
final class RewPeqRequest extends ffi.Struct {
  external ffi.Pointer<ffi.Double> freq;
  external ffi.Pointer<ffi.Double> mag;
  external ffi.Pointer<ffi.UnsignedChar> valid;
  external ffi.Pointer<ffi.Double> spread;
  @ffi.Size()
  external int n;

  @ffi.Double()
  external double fs;
  @ffi.Double()
  external double fMin;
  @ffi.Double()
  external double fMax;
  @ffi.Double()
  external double targetPercentile;
  @ffi.Double()
  external double maxCutDb;
  @ffi.Double()
  external double maxBoostDb;
  @ffi.Int()
  external int maxBands;
  @ffi.Int()
  external int reserved;

  @ffi.Double()
  external double bassShelfDb;
  @ffi.Double()
  external double bassShelfHz;
  @ffi.Double()
  external double bassShelfWidthOct;
  @ffi.Double()
  external double tiltDbPerOctave;
  @ffi.Double()
  external double tiltPivotHz;

  external ffi.Pointer<ffi.Double> freqOut;
  external ffi.Pointer<ffi.Double> gainOut;
  external ffi.Pointer<ffi.Double> qOut;
  external ffi.Pointer<ffi.Int> reasonOut;
  external ffi.Pointer<ffi.Double> confOut;
  external ffi.Pointer<ffi.Double> declinedOut;
  @ffi.Size()
  external int declinedCap;
  external ffi.Pointer<ffi.Double> errOut;
}

/// Mirrors `rew_rta_config` in core/ffi/rewcore_ffi.h.
final class RewRtaConfig extends ffi.Struct {
  @ffi.Double()
  external double fs;
  @ffi.Double()
  external double overlap;
  @ffi.Double()
  external double averaging;
  @ffi.Double()
  external double smoothFrac;
  @ffi.Double()
  external double fMin;
  @ffi.Double()
  external double fMax;
  @ffi.Size()
  external int fftSize;
  @ffi.Size()
  external int points;
  @ffi.Int()
  external int pinkWeighted;
  @ffi.Int()
  external int reserved;
}

typedef _RewRtaCreateC = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<RewRtaConfig>);
typedef RewRtaCreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<RewRtaConfig>);

typedef _RewRtaDestroyC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef RewRtaDestroyDart = void Function(ffi.Pointer<ffi.Void>);

typedef _RewRtaPushC = ffi.Size Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewRtaPushDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Double>, int);

typedef _RewRtaReadC = ffi.Size Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size);
typedef RewRtaReadDart = int Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int);

typedef _RewRtaLevelC = ffi.Double Function(ffi.Pointer<ffi.Void>);
typedef RewRtaLevelDart = double Function(ffi.Pointer<ffi.Void>);

typedef _RewRtaResetC = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int, ffi.Int);
typedef RewRtaResetDart = void Function(ffi.Pointer<ffi.Void>, int, int);

typedef _RewRtaConfigSizeC = ffi.Size Function();
typedef RewRtaConfigSizeDart = int Function();

// size_t rew_peq_request_size(void);
typedef _RewPeqRequestSizeC = ffi.Size Function();
typedef RewPeqRequestSizeDart = int Function();

// size_t rew_fit_peq(const rew_peq_request*);
typedef _RewFitPeqC = ffi.Size Function(ffi.Pointer<RewPeqRequest>);
typedef RewFitPeqDart = int Function(ffi.Pointer<RewPeqRequest>);


// int rew_assess_capture(samples*, n, fs, out*);
typedef _RewAssessCaptureC = ffi.Int Function(
    ffi.Pointer<ffi.Double>, ffi.Size, ffi.Double, ffi.Pointer<ffi.Double>);
typedef RewAssessCaptureDart = int Function(
    ffi.Pointer<ffi.Double>, int, double, ffi.Pointer<ffi.Double>);

// size_t rew_response_spread(mags*, count, n, out*);
typedef _RewResponseSpreadC = ffi.Size Function(
    ffi.Pointer<ffi.Double>, ffi.Size, ffi.Size, ffi.Pointer<ffi.Double>);
typedef RewResponseSpreadDart = int Function(
    ffi.Pointer<ffi.Double>, int, int, ffi.Pointer<ffi.Double>);

// int rew_recommend_crossover(freq*, mag*, n, dropDb, targetSlope, margin, out*);
typedef _RewRecommendCrossoverC = ffi.Int Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, ffi.Size, ffi.Double,
    ffi.Double, ffi.Double, ffi.Pointer<RewCrossoverResult>);
typedef RewRecommendCrossoverDart = int Function(
    ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>, int, double,
    double, double, ffi.Pointer<RewCrossoverResult>);

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
        rewRtaCreate =
            lib.lookupFunction<_RewRtaCreateC, RewRtaCreateDart>('rew_rta_create'),
        rewRtaDestroy = lib
            .lookupFunction<_RewRtaDestroyC, RewRtaDestroyDart>('rew_rta_destroy'),
        rewRtaPush =
            lib.lookupFunction<_RewRtaPushC, RewRtaPushDart>('rew_rta_push'),
        rewRtaSpectrum =
            lib.lookupFunction<_RewRtaReadC, RewRtaReadDart>('rew_rta_spectrum'),
        rewRtaPeakHold =
            lib.lookupFunction<_RewRtaReadC, RewRtaReadDart>('rew_rta_peak_hold'),
        rewRtaLevelDbfs = lib
            .lookupFunction<_RewRtaLevelC, RewRtaLevelDart>('rew_rta_level_dbfs'),
        rewRtaReset =
            lib.lookupFunction<_RewRtaResetC, RewRtaResetDart>('rew_rta_reset'),
        rewRtaConfigSize = lib.lookupFunction<_RewRtaConfigSizeC,
            RewRtaConfigSizeDart>('rew_rta_config_size'),
        rewCrossoverResultSize = lib.lookupFunction<_RewCrossoverResultSizeC,
            RewCrossoverResultSizeDart>('rew_crossover_result_size'),
        rewMeasureRequestSize = lib.lookupFunction<_RewMeasureRequestSizeC,
            RewMeasureRequestSizeDart>('rew_measure_request_size'),
        rewFitPeq =
            lib.lookupFunction<_RewFitPeqC, RewFitPeqDart>('rew_fit_peq'),
        rewPeqRequestSize =
            lib.lookupFunction<_RewPeqRequestSizeC, RewPeqRequestSizeDart>(
                'rew_peq_request_size'),
        rewAssessCapture =
            lib.lookupFunction<_RewAssessCaptureC, RewAssessCaptureDart>(
                'rew_assess_capture'),
        rewResponseSpread =
            lib.lookupFunction<_RewResponseSpreadC, RewResponseSpreadDart>(
                'rew_response_spread'),
        rewRecommendCrossover =
            lib.lookupFunction<_RewRecommendCrossoverC, RewRecommendCrossoverDart>(
                'rew_recommend_crossover');

  final RewVersionDart rewVersion;
  final RewGenerateSweepDart rewGenerateSweep;
  final RewGenerateNoiseDart rewGenerateNoise;
  final RewRmsDbfsDart rewRmsDbfs;
  final RewMeasureFrDart rewMeasureFr;
  final RewMeasureRequestSizeDart rewMeasureRequestSize;
  final RewFitPeqDart rewFitPeq;
  final RewPeqRequestSizeDart rewPeqRequestSize;
  final RewResponseSpreadDart rewResponseSpread;
  final RewAssessCaptureDart rewAssessCapture;
  final RewRecommendCrossoverDart rewRecommendCrossover;
  final RewCrossoverResultSizeDart rewCrossoverResultSize;
  final RewRtaCreateDart rewRtaCreate;
  final RewRtaDestroyDart rewRtaDestroy;
  final RewRtaPushDart rewRtaPush;
  final RewRtaReadDart rewRtaSpectrum;
  final RewRtaReadDart rewRtaPeakHold;
  final RewRtaLevelDart rewRtaLevelDbfs;
  final RewRtaResetDart rewRtaReset;
  final RewRtaConfigSizeDart rewRtaConfigSize;

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
