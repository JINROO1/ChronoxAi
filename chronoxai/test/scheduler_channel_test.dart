import 'package:chronoxai/domain/scheduler/scheduled_task.dart';
import 'package:chronoxai/platform/scheduler_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.chronoxai/scheduler');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (final call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('serializes a weekly prompt and forwards cancellation', () async {
    final bridge = SchedulerChannel(channel);
    final task = ScheduledTask(
      id: 'weekly',
      prompt: 'Prepare weekly report',
      scheduledAt: DateTime.utc(2026, 11, 25),
      repeat: TaskRepeat.weekly,
    );
    await bridge.schedule(task);
    await bridge.cancel(task.id);

    expect(calls.first.method, 'schedule');
    expect(calls.first.arguments['repeatDays'], 7);
    expect(calls.first.arguments['prompt'], task.prompt);
    expect(calls.last.method, 'cancel');
  });
}
