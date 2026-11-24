import 'package:chronoxai/data/runtime/pty_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/pty-list');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('decodes active terminal rows from the native bridge', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (final call) async {
      expect(call.method, 'list');
      return <Object?>[
        <String, Object?>{'id': 12, 'running': true, 'command': 'Terminal'},
      ];
    });

    final sessions = await PtySession.listActive(channel: channel);

    expect(sessions, hasLength(1));
    expect(sessions.single['id'], 12);
    expect(sessions.single['running'], isTrue);
  });
}
