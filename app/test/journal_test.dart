// The journal and the parameters it exists to revise.
//
// The important properties are about restraint: a parameter set that would let
// the app do something unsafe must be refused wherever it comes from, and a
// proposal must never take effect on its own.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/tuning_journal.dart';
import 'package:rew_mobile/src/models/tuning_parameters.dart';
import 'package:rew_mobile/src/services/journal_store.dart';

void main() {
  test('the defaults are a valid set', () {
    expect(TuningParameters.defaults.problems(), isEmpty);
  });

  test('a set that would let the app do harm is refused', () {
    // Each of these sounds plausible in isolation, which is the point: the
    // bounds exist because a good-sounding argument is not enough.
    final bad = <TuningParameters, String>{
      TuningParameters.defaults.copyWith(maxBoostDb: 12): 'boost',
      TuningParameters.defaults.copyWith(minSnrDb: 0): 'noise',
      TuningParameters.defaults.copyWith(targetPercentile: 1.5): 'percentile',
      TuningParameters.defaults.copyWith(maxCutDb: 40): 'cut',
      TuningParameters.defaults.copyWith(maxBands: 500): 'Band count',
    };
    bad.forEach((params, expectWord) {
      final problems = params.problems();
      expect(problems, isNotEmpty, reason: 'accepted $expectWord');
      expect(problems.join().toLowerCase(), contains(expectWord.toLowerCase()));
    });
  });

  test('a diff names only what changed', () {
    final changed = TuningParameters.defaults.copyWith(maxCutDb: 4);
    final diff = TuningParameters.defaults.diff(changed);
    expect(diff.keys, ['maxCutDb']);
    expect(diff['maxCutDb']!.from, 6.0);
    expect(diff['maxCutDb']!.to, 4.0);
  });

  test('entries survive being written and read back', () async {
    final dir = Directory.systemTemp.createTempSync('rew_journal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileJournalStore(dir);

    await store.append(JournalEntry(
      at: DateTime(2026, 9, 4, 12),
      event: JournalEvent.recommended,
      tuneId: 't1',
      tuneName: 'Nexon',
      parameters: TuningParameters.defaults,
      initialErrorDb: 6.6,
      finalErrorDb: 3.7,
      usableToHz: 9800,
      declined: const [(reason: 10, freqHz: 120.0)],
    ));
    await store.append(JournalEntry(
      at: DateTime(2026, 9, 4, 13),
      event: JournalEvent.verified,
      tuneId: 't1',
      tuneName: 'Nexon',
      parameters: TuningParameters.defaults,
      initialErrorDb: 3.4,
      finalErrorDb: 3.2,
    ));

    final back = await store.entries();
    expect(back.length, 2);
    // Newest first, so the most recent session is what a reader sees.
    expect(back.first.event, JournalEvent.verified);
    expect(back.last.improved, isTrue);
    expect(back.last.declined.single.reason, 10);
    expect(back.last.usableToHz, 9800);
  });

  test('one corrupt line does not hide the rest of the history', () async {
    final dir = Directory.systemTemp.createTempSync('rew_journal_bad');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileJournalStore(dir);

    await store.append(JournalEntry(
      at: DateTime(2026, 9, 4),
      event: JournalEvent.recommended,
      tuneId: 't1',
      tuneName: 'Nexon',
      parameters: TuningParameters.defaults,
    ));
    File('${dir.path}/journal.jsonl')
        .writeAsStringSync('{ not json\n', mode: FileMode.append);

    expect((await store.entries()).length, 1);
  });

  test('parameters saved outside the bounds are ignored on load', () async {
    final dir = Directory.systemTemp.createTempSync('rew_params');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileJournalStore(dir);

    // Hand-edited, or written by a version with different limits. Loading it
    // must not quietly widen what the app is willing to do.
    File('${dir.path}/tuning_parameters.json')
        .writeAsStringSync('{"maxBoostDb": 24.0}');
    expect(await store.parameters(), TuningParameters.defaults);

    await store.saveParameters(TuningParameters.defaults.copyWith(maxCutDb: 4));
    expect((await store.parameters()).maxCutDb, 4);
  });

  group('what was actually entered', () {
    const advised = PeqBand(freqHz: 1000, gainDb: -6, q: 2);

    test('a band taken as advised counts as neither changed nor skipped', () {
      const a = AppliedBand(recommended: advised, entered: advised);
      expect(a.unchanged, isTrue);
      expect(a.skipped, isFalse);
      expect(a.gainDeltaDb, 0);
    });

    test('a softened band records how far it was softened', () {
      const a = AppliedBand(
        recommended: advised,
        entered: PeqBand(freqHz: 1000, gainDb: -3, q: 2),
      );
      expect(a.unchanged, isFalse);
      // Positive means more gain than advised — here, less cut.
      expect(a.gainDeltaDb, 3);
    });

    test('a skipped band is recorded as a decision, not as missing data', () {
      const a = AppliedBand(recommended: advised);
      expect(a.skipped, isTrue);
      expect(a.gainDeltaDb, isNull);
    });

    test('rounding in the DSP is not treated as a deviation', () {
      // Entering 999.8 Hz for a 1000 Hz suggestion is the same decision.
      const a = AppliedBand(
        recommended: advised,
        entered: PeqBand(freqHz: 999.8, gainDb: -6.02, q: 2.01),
      );
      expect(a.unchanged, isTrue,
          reason: 'tiny differences would drown the real deviations in noise');
    });

    test('an entry survives being written and read back', () async {
      final dir = Directory.systemTemp.createTempSync('rew_applied');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileJournalStore(dir);

      await store.append(JournalEntry(
        at: DateTime(2026, 9, 4),
        event: JournalEvent.applied,
        tuneId: 't1',
        tuneName: 'Nexon',
        parameters: TuningParameters.defaults,
        applied: const [
          AppliedBand(recommended: advised, entered: advised),
          AppliedBand(
            recommended: PeqBand(freqHz: 60, gainDb: -6, q: 1),
            entered: PeqBand(freqHz: 60, gainDb: -3, q: 1),
          ),
          AppliedBand(recommended: PeqBand(freqHz: 8000, gainDb: -2, q: 8)),
        ],
      ));

      final back = (await store.entries()).single;
      expect(back.event, JournalEvent.applied);
      expect(back.applied.length, 3);
      expect(back.changedCount, 1);
      expect(back.skippedCount, 1);
      expect(back.applied[1].gainDeltaDb, 3);
    });
  });

  test('a proposal does nothing until it is applied', () async {
    final store = MemoryJournalStore();
    final proposal = ParameterProposal(
      at: DateTime(2026, 9, 4),
      parameters: TuningParameters.defaults.copyWith(maxCutDb: 4),
      rationale: 'The cut limit keeps being hit and reported as a level trim.',
    );
    await store.addProposal(proposal);

    expect((await store.parameters()).maxCutDb, 6.0,
        reason: 'storing a proposal must not change how the app tunes');

    await store.saveParameters(proposal.parameters);
    await store.replaceProposals([proposal.markApplied()]);
    expect((await store.parameters()).maxCutDb, 4.0);
    expect((await store.proposals()).single.applied, isTrue);
  });
}
