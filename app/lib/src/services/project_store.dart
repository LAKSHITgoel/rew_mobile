// Persistence for saved tunes. Serializes projects to JSON files in the app's
// documents directory. Falls back to an in-memory list when a file location
// isn't available (e.g. widget tests), so the app remains usable everywhere.
import 'dart:convert';
import 'dart:io';

import '../models/project.dart';

abstract class ProjectStore {
  Future<List<TuneProject>> list();
  Future<void> save(TuneProject project);
  Future<void> delete(String id);
}

/// In-memory store — the default, always available, no plugins required.
class MemoryProjectStore implements ProjectStore {
  final Map<String, TuneProject> _projects = {};

  @override
  Future<List<TuneProject>> list() async {
    final all = _projects.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
  }

  @override
  Future<void> save(TuneProject project) async {
    _projects[project.id] = project;
  }

  @override
  Future<void> delete(String id) async {
    _projects.remove(id);
  }
}

/// File-backed store. Pass a directory (obtain it with `path_provider`'s
/// getApplicationDocumentsDirectory() in the app; injected here to keep this file
/// plugin-free and testable).
class FileProjectStore implements ProjectStore {
  FileProjectStore(this.directory);
  final Directory directory;

  File _file(String id) => File('${directory.path}/tune_$id.json');

  @override
  Future<List<TuneProject>> list() async {
    if (!await directory.exists()) return [];
    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'));
    final out = <TuneProject>[];
    for (final f in files) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        out.add(TuneProject.fromJson(json));
      } catch (_) {
        // Skip corrupt files rather than crashing the list.
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  @override
  Future<void> save(TuneProject project) async {
    await directory.create(recursive: true);
    await _file(project.id).writeAsString(jsonEncode(project.toJson()));
  }

  @override
  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
  }
}
