// What is actually installed in the car. Everything downstream — which channels
// get measured, which sweep band each one gets, and what the DSP can even
// control — follows from this, so it is asked once up front.
import 'measurement.dart';

/// How the front stage is built. "Active" means each driver has its own DSP
/// channel; "passive" means one DSP channel feeds a passive crossover, so the
/// drivers behind it cannot be measured or delayed separately.
enum FrontConfig { coax, twoWayPassive, twoWayActive, threeWayPassive, threeWayActive }

enum RearConfig { none, coax, twoWayPassive, twoWayActive }

enum SubConfig { none, one, stereo }

extension FrontConfigInfo on FrontConfig {
  String get label => switch (this) {
        FrontConfig.coax => 'Coaxial (one driver per side)',
        FrontConfig.twoWayPassive => '2-way passive (tweeter + mid, one DSP channel)',
        FrontConfig.twoWayActive => '2-way active (tweeter + mid, separate channels)',
        FrontConfig.threeWayPassive => '3-way passive (one DSP channel per side)',
        FrontConfig.threeWayActive => '3-way active (tweeter + mid + midbass)',
      };
  bool get isActive =>
      this == FrontConfig.twoWayActive || this == FrontConfig.threeWayActive;
}

extension RearConfigInfo on RearConfig {
  String get label => switch (this) {
        RearConfig.none => 'None / not used',
        RearConfig.coax => 'Coaxial',
        RearConfig.twoWayPassive => '2-way passive',
        RearConfig.twoWayActive => '2-way active',
      };
  bool get isActive => this == RearConfig.twoWayActive;
}

extension SubConfigInfo on SubConfig {
  String get label => switch (this) {
        SubConfig.none => 'No subwoofer',
        SubConfig.one => 'One subwoofer',
        SubConfig.stereo => 'Two subwoofers (stereo)',
      };
}

/// The installed system, and the measurement plan it implies.
class CarSetup {
  const CarSetup({
    this.front = FrontConfig.twoWayActive,
    this.rear = RearConfig.coax,
    this.sub = SubConfig.one,
  });

  final FrontConfig front;
  final RearConfig rear;
  final SubConfig sub;

  CarSetup copyWith({FrontConfig? front, RearConfig? rear, SubConfig? sub}) =>
      CarSetup(front: front ?? this.front, rear: rear ?? this.rear, sub: sub ?? this.sub);

  /// Every channel the DSP can control independently — which is exactly what can
  /// be measured, crossed over and delayed on its own.
  List<Channel> get channels {
    final out = <Channel>[];
    for (final side in const ['l', 'r']) {
      final S = side == 'l' ? 'L' : 'R';
      switch (front) {
        case FrontConfig.threeWayActive:
          out.add(Channel('f${side}_tweeter', 'Front $S Tweeter', DriverRole.tweeter));
          out.add(Channel('f${side}_mid', 'Front $S Midrange', DriverRole.midrange));
          out.add(Channel('f${side}_midbass', 'Front $S Midbass', DriverRole.midbass));
        case FrontConfig.twoWayActive:
          out.add(Channel('f${side}_tweeter', 'Front $S Tweeter', DriverRole.tweeter));
          out.add(Channel('f${side}_mid', 'Front $S Midrange', DriverRole.midrange));
        case FrontConfig.coax:
        case FrontConfig.twoWayPassive:
        case FrontConfig.threeWayPassive:
          out.add(Channel('f$side', 'Front $S', DriverRole.fullRange));
      }
    }
    for (final side in const ['l', 'r']) {
      final S = side == 'l' ? 'L' : 'R';
      switch (rear) {
        case RearConfig.none:
          break;
        case RearConfig.twoWayActive:
          out.add(Channel('r${side}_tweeter', 'Rear $S Tweeter', DriverRole.tweeter));
          out.add(Channel('r${side}_mid', 'Rear $S Midrange', DriverRole.midrange));
        case RearConfig.coax:
        case RearConfig.twoWayPassive:
          out.add(Channel('r$side', 'Rear $S', DriverRole.fullRange));
      }
    }
    switch (sub) {
      case SubConfig.none:
        break;
      case SubConfig.one:
        out.add(const Channel('sub', 'Subwoofer', DriverRole.sub));
      case SubConfig.stereo:
        out.add(const Channel('sub_l', 'Subwoofer L', DriverRole.sub));
        out.add(const Channel('sub_r', 'Subwoofer R', DriverRole.sub));
    }
    return out;
  }

  /// The sweep band to use for a channel — narrow for a tweeter (a full-range
  /// sweep can destroy one), wide for anything running full range.
  static SweepBand bandFor(Channel ch) => switch (ch.role) {
        DriverRole.tweeter => SweepBand.tweeter,
        DriverRole.midrange => SweepBand.midrange,
        DriverRole.midbass => SweepBand.midbass,
        DriverRole.sub => SweepBand.sub,
        DriverRole.fullRange => SweepBand.full,
      };

  /// Plain-language notes about what this system does and doesn't allow.
  List<String> get planNotes {
    final notes = <String>[];
    notes.add('${channels.length} independently controllable channels to measure.');
    if (!front.isActive) {
      notes.add(
          'The front is passive, so its drivers share one DSP channel per side: '
          'you can set a crossover for the pair and delay the pair, but not the '
          'tweeter and mid separately.');
    } else {
      notes.add(
          'The front is active, so each driver gets its own crossover, delay and '
          'EQ — measure them one at a time with the others muted.');
    }
    if (rear == RearConfig.none) {
      notes.add('No rears: the whole tune is front stage plus sub.');
    }
    if (sub == SubConfig.none) {
      notes.add(
          'No sub: high-pass the front so it is not asked to reproduce bass it '
          'cannot handle.');
    }
    return notes;
  }

  Map<String, dynamic> toJson() =>
      {'front': front.index, 'rear': rear.index, 'sub': sub.index};

  factory CarSetup.fromJson(Map<String, dynamic> j) => CarSetup(
        front: FrontConfig.values[(j['front'] as num?)?.toInt() ?? 2],
        rear: RearConfig.values[(j['rear'] as num?)?.toInt() ?? 1],
        sub: SubConfig.values[(j['sub'] as num?)?.toInt() ?? 1],
      );
}
