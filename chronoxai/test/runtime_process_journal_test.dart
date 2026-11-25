import 'dart:convert';
import 'dart:io';

import 'package:chronoxai/data/runtime/runtime_process_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chronox-process-journal-');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('persists exit state, output count, and timestamp', () async {
    final journal = await RuntimeProcessJournal.open(directory.path);
    final startedAt = DateTime.utc(2026, 11, 23, 12);
    await journal.started(
      id: 'pty-1',
      title: 'shell',
      startedAt: startedAt,
    );
    await journal.finished(
      id: 'pty-1',
      state: RuntimeProcessState.exited,
      outputBytes: 128,
      exitCode: 7,
      endedAt: startedAt.add(const Duration(seconds: 4)),
    );

    final json = jsonDecode(await journal.file.readAsString())
        as Map<String, Object?>;
    final record = RuntimeProcessRecord.fromJson(
      (json['records']! as List<Object?>).single as Map<String, Object?>,
    );
    expect(record.state, RuntimeProcessState.exited);
    expect(record.exitCode, 7);
    expect(record.outputBytes, 128);
    expect(record.endedAt, startedAt.add(const Duration(seconds: 4)));
  });

  test('marks a previously running process orphaned without resuming it',
      () async {
    final file = File('${directory.path}/runtime-processes.json');
    await file.writeAsString(jsonEncode(<String, Object?>{
      'version': 1,
      'records': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'pty-old',
          'title': 'server',
          'startedAt': '2026-11-23T12:00:00.000Z',
          'endedAt': null,
          'state': 'running',
          'exitCode': null,
          'outputBytes': 900,
        },
      ],
    }));

    final journal = await RuntimeProcessJournal.open(directory.path);

    expect(journal.records.single.state, RuntimeProcessState.orphaned);
    expect(journal.records.single.endedAt, isNotNull);
    expect(journal.records.single.exitCode, isNull);
    final persisted = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(
      (((persisted['records']! as List<Object?>).single
              as Map<String, Object?>)['state']),
      'orphaned',
    );
  });

  test('caps journal history at its documented record limit', () async {
    final journal = await RuntimeProcessJournal.open(directory.path);
    for (var index = 0; index < RuntimeProcessJournal.maxRecords + 2; index++) {
      await journal.started(
        id: 'pty-$index',
        title: 'shell',
        startedAt: DateTime.utc(2026, 11, 23).add(Duration(seconds: index)),
      );
    }

    expect(journal.records, hasLength(RuntimeProcessJournal.maxRecords));
    expect(journal.records.first.id, 'pty-2');
  });
}
