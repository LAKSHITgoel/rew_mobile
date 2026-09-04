// Where the tuning journal, the current heuristics and any pending proposals
// live on disk.
//
// The journal is one JSON object per line rather than a single document: it is
// appended to after every measurement, and a whole-file rewrite each time is
// both slower and a good way to lose the lot if the app dies mid-write.
import 'dart:convert';
import 'dart:io';

import '../models/tuning_journal.dart';
import '../models/tuning_parameters.dart';

abstract class JournalStore {
  Future<void> append(JournalEntry entry);
  Future<List<JournalEntry>> entries({int limit = 200});

  Future<TuningParameters> parameters();
  Future<void> saveParameters(TuningParameters p);

  Future<List<ParameterProposal>> proposals();
  Future<void> addProposal(ParameterProposal p);
  Future<void> replaceProposals(List<ParameterProposal> all);
}

class FileJournalStore implements JournalStore {
  FileJournalStore(this.dir);
  final Directory dir;

  File get _journal => File('${dir.path}/journal.jsonl');
  File get _params => File('${dir.path}/tuning_parameters.json');
  File get _proposals => File('${dir.path}/parameter_proposals.json');

  Future<void> _ensure() async {
    if (!dir.existsSync()) await dir.create(recursive: true);
  }

  @override
  Future<void> append(JournalEntry entry) async {
    await _ensure();
    await _journal.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<List<JournalEntry>> entries({int limit = 200}) async {
    if (!_journal.existsSync()) return const [];
    final lines = await _journal.readAsLines();
    final out = <JournalEntry>[];
    // Newest first, and stop once enough have been read: the journal only grows.
    for (var i = lines.length - 1; i >= 0 && out.length < limit; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        out.add(JournalEntry.fromJson(
            jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // One malformed line must not hide the rest of the history.
      }
    }
    return out;
  }

  @override
  Future<TuningParameters> parameters() async {
    if (!_params.existsSync()) return TuningParameters.defaults;
    try {
      final p = TuningParameters.fromJson(
          jsonDecode(await _params.readAsString()) as Map<String, dynamic>);
      // Never hand back a set that would not be accepted as a proposal: a file
      // edited by hand, or written by an older version, must not quietly widen
      // the limits the app enforces.
      return p.isValid ? p : TuningParameters.defaults;
    } catch (_) {
      return TuningParameters.defaults;
    }
  }

  @override
  Future<void> saveParameters(TuningParameters p) async {
    await _ensure();
    await _params.writeAsString(jsonEncode(p.toJson()), flush: true);
  }

  @override
  Future<List<ParameterProposal>> proposals() async {
    if (!_proposals.existsSync()) return const [];
    try {
      final list = jsonDecode(await _proposals.readAsString()) as List;
      return [
        for (final p in list)
          ParameterProposal.fromJson((p as Map).cast<String, dynamic>())
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> addProposal(ParameterProposal p) async {
    final all = [...await proposals(), p];
    await replaceProposals(all);
  }

  @override
  Future<void> replaceProposals(List<ParameterProposal> all) async {
    await _ensure();
    await _proposals.writeAsString(
      jsonEncode([for (final p in all) p.toJson()]),
      flush: true,
    );
  }
}

/// For tests and for desktop runs with nowhere to write.
class MemoryJournalStore implements JournalStore {
  final List<JournalEntry> _entries = [];
  final List<ParameterProposal> _proposals = [];
  TuningParameters _params = TuningParameters.defaults;

  @override
  Future<void> append(JournalEntry entry) async => _entries.add(entry);

  @override
  Future<List<JournalEntry>> entries({int limit = 200}) async =>
      _entries.reversed.take(limit).toList();

  @override
  Future<TuningParameters> parameters() async => _params;

  @override
  Future<void> saveParameters(TuningParameters p) async => _params = p;

  @override
  Future<List<ParameterProposal>> proposals() async => List.of(_proposals);

  @override
  Future<void> addProposal(ParameterProposal p) async => _proposals.add(p);

  @override
  Future<void> replaceProposals(List<ParameterProposal> all) async {
    _proposals
      ..clear()
      ..addAll(all);
  }
}
