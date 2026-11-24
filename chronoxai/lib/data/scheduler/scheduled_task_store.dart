import 'dart:convert';
import 'dart:io';

import '../../domain/scheduler/scheduled_task.dart';

/// JSON persistence for scheduled prompts; writes atomically via a sibling file.
class ScheduledTaskStore {
  const ScheduledTaskStore(this.file);
  final File file;

  Future<List<ScheduledTask>> readAll() async {
    if (!await file.exists()) return const <ScheduledTask>[];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) throw const FormatException('Invalid task store.');
    return decoded
        .whereType<Map<Object?, Object?>>()
        .map((final row) => ScheduledTask.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<void> writeAll(final List<ScheduledTask> tasks) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(tasks.map((final task) => task.toJson()).toList()),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
