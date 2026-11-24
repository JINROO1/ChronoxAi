import 'package:flutter/services.dart';

import '../domain/scheduler/scheduled_task.dart';

/// Android inexact alarm bridge. Desktop tests can inject a fake MethodChannel.
class SchedulerChannel {
  const SchedulerChannel([this.channel = _defaultChannel]);
  static const MethodChannel _defaultChannel =
      MethodChannel('app.chronoxai/scheduler');
  final MethodChannel channel;

  Future<void> schedule(final ScheduledTask task) async {
    await channel.invokeMethod<bool>('schedule', <String, Object?>{
      'id': task.id,
      'prompt': task.prompt,
      'atMillis': task.scheduledAt.millisecondsSinceEpoch,
      'repeatDays': switch (task.repeat) {
        TaskRepeat.none => 0,
        TaskRepeat.daily => 1,
        TaskRepeat.weekly => 7,
      },
    });
  }

  Future<void> cancel(final String id) =>
      channel.invokeMethod<void>('cancel', <String, Object?>{'id': id});

  Future<String?> takeLaunchPrompt() =>
      channel.invokeMethod<String?>('takeLaunchPrompt');
}
