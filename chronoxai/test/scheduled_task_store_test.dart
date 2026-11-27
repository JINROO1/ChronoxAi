import 'dart:io';

import 'package:chronoxai/data/scheduler/scheduled_task_store.dart';
import 'package:chronoxai/domain/scheduler/scheduled_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late ScheduledTaskStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chronox-schedule-');
    store = ScheduledTaskStore(File('${directory.path}/tasks.json'));
  });

  tearDown(() async => directory.delete(recursive: true));

  test('missing store is an empty list; tasks round-trip as JSON', () async {
    expect(await store.readAll(), isEmpty);
    final task = ScheduledTask(
      id: 'task-1',
      prompt: 'Revisar el resumen',
      scheduledAt: DateTime.utc(2026, 11, 24, 12),
      repeat: TaskRepeat.daily,
    );

    await store.writeAll(<ScheduledTask>[task]);

    final restored = await store.readAll();
    expect(restored, hasLength(1));
    expect(restored.single.id, 'task-1');
    expect(restored.single.prompt, 'Revisar el resumen');
    expect(restored.single.repeat, TaskRepeat.daily);
  });

  test('rejects malformed top-level JSON shape', () async {
    await store.file.writeAsString('{"not":"a list"}');
    await expectLater(store.readAll(), throwsFormatException);
  });
}
