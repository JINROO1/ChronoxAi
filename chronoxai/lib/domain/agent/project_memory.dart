import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The three intentionally separate kinds of durable project context.
enum ProjectMemoryKind { fact, preference, conversation }

class ProjectMemoryEntry {
  const ProjectMemoryEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.source,
    required this.createdAt,
    required this.confidence,
  });

  final String id;
  final ProjectMemoryKind kind;
  final String text;
  final String source;
  final DateTime createdAt;
  final double confidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        'text': text,
        'source': source,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'confidence': confidence,
      };

  factory ProjectMemoryEntry.fromJson(final Map<String, Object?> json) =>
      ProjectMemoryEntry(
        id: json['id']! as String,
        kind: ProjectMemoryKind.values.firstWhere(
          (final kind) => kind.name == json['kind'],
        ),
        text: json['text']! as String,
        source: json['source']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
        confidence: (json['confidence']! as num).toDouble(),
      );
}

/// Workspace-isolated, private-app-storage memory. It never stores chat logs or
/// credentials; entries are explicit, sourced, dated, and confidence-rated.
class ProjectMemoryStore {
  ProjectMemoryStore._({required this.file, required this.workspacePath});

  static const int maxEntries = 100;
  static const int maxTextLength = 800;
  static const int maxSourceLength = 300;
  static const int maxStoreBytes = 256000;
  static const int maxContextCharacters = 2400;

  static final RegExp _secretPattern = RegExp(
    r'(api[_ -]?key|access[_ -]?token|password|passwd|secret|authorization)\s*[:=]|\bsk-[A-Za-z0-9_-]{16,}|\bgh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b',
    caseSensitive: false,
  );

  final File file;
  final String workspacePath;
  List<ProjectMemoryEntry> _entries = <ProjectMemoryEntry>[];
  bool enabled = true;
  List<String> excludedTopics = <String>[];
  List<String> excludedSources = <String>[];
  int rejectedOnLoad = 0;
  String? loadWarning;
  bool _unreadable = false;
  bool get canWrite => !_unreadable;
  Future<void> _writeTail = Future<void>.value();

  List<ProjectMemoryEntry> get entries =>
      List<ProjectMemoryEntry>.unmodifiable(_entries);

  static Future<ProjectMemoryStore> open({
    required final String workspacePath,
    required final Directory storageDirectory,
  }) async {
    final normalizedWorkspace = p.normalize(p.absolute(workspacePath));
    final workspaceHash =
        sha256.convert(utf8.encode(normalizedWorkspace)).toString();
    final directory =
        Directory(p.join(storageDirectory.path, 'project-memory'));
    await directory.create(recursive: true);
    final store = ProjectMemoryStore._(
      file: File(p.join(directory.path, '$workspaceHash.json')),
      workspacePath: normalizedWorkspace,
    );
    try {
      await store._load();
    } catch (error) {
      store._unreadable = true;
      store.loadWarning = error.toString();
    }
    return store;
  }

  Future<void> _load() async {
    if (!await file.exists()) return;
    final bytes = await file.length();
    if (bytes > maxStoreBytes) {
      throw const FormatException('Project memory exceeds the allowed size.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> || decoded['version'] != 1) {
      throw const FormatException('Unsupported project memory format.');
    }
    final rawEntries = decoded['entries'];
    if (rawEntries is! List<Object?> || rawEntries.length > maxEntries) {
      throw const FormatException('Invalid project memory entry list.');
    }
    _entries = <ProjectMemoryEntry>[];
    for (final raw in rawEntries.whereType<Map<String, Object?>>()) {
      try {
        final entry = ProjectMemoryEntry.fromJson(raw);
        if (entry.text.length > maxTextLength ||
            entry.source.length > maxSourceLength ||
            entry.confidence < 0 ||
            entry.confidence > 1 ||
            _secretPattern.hasMatch(entry.text) ||
            _secretPattern.hasMatch(entry.source)) {
          rejectedOnLoad++;
          continue;
        }
        _entries.add(entry);
      } catch (_) {
        rejectedOnLoad++;
      }
    }
    enabled = decoded['enabled'] as bool? ?? true;
    excludedTopics = _normalizeExclusions(decoded['excludedTopics']);
    excludedSources = _normalizeExclusions(decoded['excludedSources']);
  }

  Future<ProjectMemoryEntry> add({
    required final ProjectMemoryKind kind,
    required final String text,
    required final String source,
    required final double confidence,
  }) async {
    _ensureWritable();
    final cleanText = _validateText(text, maxTextLength, 'text');
    final cleanSource = _validateText(source, maxSourceLength, 'source');
    if (confidence < 0 || confidence > 1 || !confidence.isFinite) {
      throw ArgumentError.value(
          confidence, 'confidence', 'Must be between 0 and 1.');
    }
    final now = DateTime.now().toUtc();
    final id =
        '${now.microsecondsSinceEpoch}-${sha256.convert(utf8.encode('$kind:$cleanText')).toString().substring(0, 10)}';
    final entry = ProjectMemoryEntry(
      id: id,
      kind: kind,
      text: cleanText,
      source: cleanSource,
      createdAt: now,
      confidence: confidence,
    );
    await _enqueue(() async {
      if (_entries.length >= maxEntries) {
        throw StateError(
            'Project memory is full (maximum $maxEntries entries).');
      }
      if (_entries.any((final current) =>
          current.kind == kind &&
          current.text.toLowerCase() == cleanText.toLowerCase())) {
        throw StateError('An equivalent memory entry already exists.');
      }
      _entries = <ProjectMemoryEntry>[..._entries, entry];
      try {
        await _persist();
      } catch (_) {
        _entries.removeWhere((final current) => current.id == entry.id);
        rethrow;
      }
    });
    return entry;
  }

  Future<void> update(
    final String id, {
    required final ProjectMemoryKind kind,
    required final String text,
    required final String source,
    required final double confidence,
  }) async {
    _ensureWritable();
    final cleanText = _validateText(text, maxTextLength, 'text');
    final cleanSource = _validateText(source, maxSourceLength, 'source');
    if (confidence < 0 || confidence > 1 || !confidence.isFinite) {
      throw ArgumentError.value(
          confidence, 'confidence', 'Must be between 0 and 1.');
    }
    await _enqueue(() async {
      final index = _entries.indexWhere((final entry) => entry.id == id);
      if (index < 0) throw StateError('Memory entry not found.');
      final old = _entries[index];
      if (_entries.any((final entry) =>
          entry.id != id &&
          entry.kind == kind &&
          entry.text.toLowerCase() == cleanText.toLowerCase())) {
        throw StateError('An equivalent memory entry already exists.');
      }
      final replacement = ProjectMemoryEntry(
        id: old.id,
        kind: kind,
        text: cleanText,
        source: cleanSource,
        createdAt: old.createdAt,
        confidence: confidence,
      );
      final before = _entries;
      _entries = List<ProjectMemoryEntry>.of(_entries)..[index] = replacement;
      try {
        await _persist();
      } catch (_) {
        _entries = before;
        rethrow;
      }
    });
  }

  Future<void> remove(final String id) => _enqueue(() async {
        _ensureWritable();
        final before = _entries;
        _entries = _entries.where((final entry) => entry.id != id).toList();
        if (_entries.length == before.length) return;
        try {
          await _persist();
        } catch (_) {
          _entries = before;
          rethrow;
        }
      });

  Future<void> clear() => _enqueue(() async {
        final beforeEntries = _entries;
        final beforeEnabled = enabled;
        final beforeTopics = excludedTopics;
        final beforeSources = excludedSources;
        final beforeWarning = loadWarning;
        final wasUnreadable = _unreadable;
        _entries = <ProjectMemoryEntry>[];
        enabled = true;
        excludedTopics = <String>[];
        excludedSources = <String>[];
        try {
          if (await file.exists()) await file.delete();
          loadWarning = null;
          _unreadable = false;
          rejectedOnLoad = 0;
        } catch (_) {
          _entries = beforeEntries;
          enabled = beforeEnabled;
          excludedTopics = beforeTopics;
          excludedSources = beforeSources;
          loadWarning = beforeWarning;
          _unreadable = wasUnreadable;
          rethrow;
        }
      });

  Future<void> configure({
    required final bool enabled,
    required final Iterable<String> excludedTopics,
    required final Iterable<String> excludedSources,
  }) =>
      _enqueue(() async {
        _ensureWritable();
        final beforeEnabled = this.enabled;
        final beforeTopics = this.excludedTopics;
        final beforeSources = this.excludedSources;
        this.enabled = enabled;
        this.excludedTopics = _normalizeExclusions(excludedTopics);
        this.excludedSources = _normalizeExclusions(excludedSources);
        try {
          await _persist();
        } catch (_) {
          this.enabled = beforeEnabled;
          this.excludedTopics = beforeTopics;
          this.excludedSources = beforeSources;
          rethrow;
        }
      });

  /// Returns only relevant, allowed context within a hard prompt budget.
  String contextFor(final String userInput) {
    if (!enabled || _entries.isEmpty) return '';
    final queryWords = _words(userInput);
    if (queryWords.isEmpty) return '';
    final candidates = _entries.where((final entry) {
      final corpus = '${entry.text} ${entry.source}'.toLowerCase();
      return !excludedTopics.any((final topic) =>
              topic.isNotEmpty && corpus.contains(topic.toLowerCase())) &&
          !excludedSources.any((final source) =>
              source.isNotEmpty &&
              entry.source.toLowerCase().contains(source.toLowerCase()));
    }).toList();
    int overlapCount(final ProjectMemoryEntry entry) {
      final corpus = '${entry.text} ${entry.source}'.toLowerCase();
      return queryWords
          .where((final word) => corpus.contains(word))
          .length;
    }

    int score(final ProjectMemoryEntry entry) {
      final confidence = (entry.confidence * 10).round();
      final kindWeight = entry.kind == ProjectMemoryKind.preference ? 1 : 0;
      return overlapCount(entry) * 100 + confidence + kindWeight;
    }

    candidates.sort((final left, final right) {
      final byScore = score(right).compareTo(score(left));
      return byScore != 0 ? byScore : right.createdAt.compareTo(left.createdAt);
    });
    final selected = candidates
        .where((final entry) => overlapCount(entry) > 0)
        .take(8)
        .toList();
    if (selected.isEmpty) return '';

    final buffer = StringBuffer();
    for (final entry in selected) {
      final block = '- [${entry.kind.name}; fuente: ${entry.source}; '
          '${entry.createdAt.toIso8601String().split('T').first}; '
          'confianza ${(entry.confidence * 100).round()}%] ${entry.text}\n';
      if (buffer.length + block.length > maxContextCharacters) break;
      buffer.write(block);
    }
    return buffer.isEmpty ? '' : buffer.toString().trimRight();
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(
        <String, Object?>{
          'version': 1,
          'enabled': enabled,
          'excludedTopics': excludedTopics,
          'excludedSources': excludedSources,
          'entries': _entries.map((final entry) => entry.toJson()).toList(),
        },
      );

  Future<void> _persist() async {
    final payload = exportJson();
    if (utf8.encode(payload).length > maxStoreBytes) {
      throw StateError('Project memory exceeds the allowed size.');
    }
    await file.parent.create(recursive: true);
    final temp =
        File('${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _enqueue(final Future<void> Function() action) {
    final completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        await action();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _ensureWritable() {
    if (_unreadable) {
      throw StateError(
          'Memory storage could not be read. Clear it explicitly before writing.');
    }
  }

  static String _validateText(
      final String value, final int max, final String field) {
    final result = value.trim();
    if (result.isEmpty || result.length > max) {
      throw ArgumentError('$field must contain 1–$max characters.');
    }
    if (_secretPattern.hasMatch(result)) {
      throw ArgumentError(
          'Possible credential detected; project memory rejects secrets.');
    }
    return result;
  }

  static List<String> _normalizeExclusions(final Object? values) {
    final iterable =
        values is Iterable ? values.whereType<String>() : const <String>[];
    return iterable
        .map((final value) => value.trim())
        .where((final value) => value.isNotEmpty && value.length <= 100)
        .take(30)
        .toSet()
        .toList()
      ..sort();
  }

  static Set<String> _words(final String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9_áéíóúüñ]+'))
      .where((final word) => word.length >= 3)
      .toSet();
}
