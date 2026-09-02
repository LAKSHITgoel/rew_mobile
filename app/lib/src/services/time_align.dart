// Manual time-alignment helpers.
//
// The app deliberately does NOT try to *measure* arrival times: the sweep goes
// out over Bluetooth to the head unit, and that path's latency is neither known
// nor stable, so any absolute delay it derived would be fiction. What is
// perfectly sound is the manual method every installer uses — compute delays
// from physical distances, then refine by ear with a centred noise signal. The
// distances are real, so the *differences* between channels are real.
import 'dart:math' as math;

/// Speed of sound in dry air, m/s. Temperature matters: ~0.6 m/s per °C, so a
/// cold car and a hot car differ by a few percent.
double speedOfSound({double celsius = 20}) => 331.3 + 0.606 * celsius;

/// Delay (ms) each channel needs so all arrivals land together at the seat.
///
/// The *farthest* driver sets the reference and gets zero delay; every closer
/// driver is delayed by the extra time its shorter path saves. Distances are in
/// centimetres, keyed by channel id. Channels with a null/absent distance are
/// omitted.
Map<String, double> delaysFromDistancesCm(
  Map<String, double> distancesCm, {
  double celsius = 20,
  double maxDelayMs = 20,
}) {
  final valid = <String, double>{
    for (final e in distancesCm.entries)
      if (e.value.isFinite && e.value > 0) e.key: e.value,
  };
  if (valid.isEmpty) return {};

  final farthestCm = valid.values.reduce(math.max);
  final c = speedOfSound(celsius: celsius); // m/s
  return {
    for (final e in valid.entries)
      e.key: (((farthestCm - e.value) / 100.0) / c * 1000.0)
          .clamp(0.0, maxDelayMs)
          .toDouble(),
  };
}
