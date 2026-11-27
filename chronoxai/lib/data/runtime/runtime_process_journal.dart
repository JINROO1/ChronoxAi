import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum RuntimeProcessState { running, exited, failed, closed, orphaned }

class RuntimeProcessRecord {
  const RuntimeProcessRecord({
    required this.id,
    required this.title,
    required this.startedAt,
    required this.state,
    required this.outputBytes,
    this.endedAt,
    this.exitCode,
  });

  final String id;
  final String title;
  final DateTime startedAt;
  final DateTime? endedAt;
  final RuntimeProcessState state;
  final int? exitCode;
  final int outputBytes;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'endedAt': endedAt?.toUtc().toIso8601String(),
        'state': state.name,
        'exitCode': exitCode,
        'outputBytes': outputBytes,
      };

  factory RuntimeProcessRecord.fromJson(final Map<String, Object?> json) =>
      RuntimeProcessRecord(
        id: json['id']! as String,
        title: json['title']! as String,
        startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
        endedAt: json['endedAt'] == null
            ? null
            : DateTime.parse(json['endedAt']! as String).toUtc(),
        state: RuntimeProcessState.values.firstWhere(
          (final state) => state.name == json['state'],
        ),
        exitCode: json['exitCode'] as int?,
        outputBytes: (json['outputBytes'] as int?) ?? 0,
      );
}

/// Small private-app journal. A process marked running at startup becomes
/// orphaned: metadata is recoverable, but a dead process is never "resumed".
class RuntimeProcessJournal {
  RuntimeProcessJournal._(this.file);

  static const int maxRecords = 100;
  static const int maxJournalBytes = 256000;
  static final Map<String, Future<RuntimeProcessJournal>> _instances =
      <String, Future<RuntimeProcessJournal>>{};

  final File file;
  final List<RuntimeProcessRecord> _records = <RuntimeProcessRecord>[];
  Future<void> _tail = Future<void>.value();

  List<RuntimeProcessRecord> get records =>
      List<RuntimeProcessRecord>.unmodifiable(_records);

  Future<void> flush() => _tail;

  static Future<RuntimeProcessJournal> open(final String sessionsDirectory) {
    final path = p.join(sessionsDirectory, 'runtime-processes.json');
    return _instances.putIfAbsent(path, () async {
      final journal = RuntimeProcessJournal._(File(path));
      try {
        await journal._load();
      } on Object {
        // A corrupt history must not prevent opening a runtime or terminal.
        journal._records.clear();
      }
      return journal;
    });
  }

  Future<void> _load() async {
    if (!await file.exists()) return;
    if (await file.length() > maxJournalBytes) {
      throw const FormatException('Runtime process journal is too large.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> || decoded['version'] != 1) {
      throw const FormatException('Unsupported runtime process journal.');
    }
    final raw = decoded['records'];
    if (raw is! List<Object?> || raw.length > maxRecords) {
      throw const FormatException('Invalid runtime process journal records.');
    }
    for (final item in raw.whereType<Map<String, Object?>>()) {
      try {
        _records.add(RuntimeProcessRecord.fromJson(item));
      } catch (_) {
        // Ignore an individual malformed record, never invent a live process.
      }
    }
    var recovered = false;
    for (var index = 0; index < _records.length; index++) {
      final record = _records[index];
      if (record.state == RuntimeProcessState.running) {
        _records[index] = RuntimeProcessRecord(
          id: record.id,
          title: record.title,
          startedAt: record.startedAt,
          endedAt: DateTime.now().toUtc(),
          state: RuntimeProcessState.orphaned,
          exitCode: null,
          outputBytes: record.outputBytes,
        );
        recovered = true;
      }
    }
    if (recovered) await _persist();
  }

  Future<void> started({
    required final String id,
    required final String title,
    required final DateTime startedAt,
  }) =>
      _enqueue(() async {
        _records.removeWhere((final record) => record.id == id);
        _records.add(RuntimeProcessRecord(
          id: id,
          title: title,
          startedAt: startedAt.toUtc(),
          state: RuntimeProcessState.running,
          outputBytes: 0,
        ));
        _trim();
        await _persist();
      });

  Future<void> finished({
    required final String id,
    required final RuntimeProcessState state,
    required final int outputBytes,
    required final int? exitCode,
    required final DateTime endedAt,
  }) =>
      _enqueue(() async {
        final index = _records.indexWhere((final record) => record.id == id);
        if (index < 0) return;
        final current = _records[index];
        _records[index] = RuntimeProcessRecord(
          id: current.id,
          title: current.title,
          startedAt: current.startedAt,
          endedAt: endedAt.toUtc(),
          state: state,
          exitCode: exitCode,
          outputBytes: outputBytes,
        );
        await _persist();
      });

  void _trim() {
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
    }
  }

  Future<void> _persist() async {
    final payload = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'version': 1,
        'records': _records.map((final record) => record.toJson()).toList(),
      },
    );
    if (utf8.encode(payload).length > maxJournalBytes) {
      throw StateError('Runtime process journal exceeds its size limit.');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _enqueue(final Future<void> Function() action) {
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await action();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
