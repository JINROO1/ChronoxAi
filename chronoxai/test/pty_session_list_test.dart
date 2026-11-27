import 'package:chronoxai/data/runtime/pty_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active sessions are listed and can be closed by id', () async {
    final session = PtySession(command: 'proot → bash');
    expect(PtySession.listActive(), isEmpty);

    final ok = await session.start(
      binary: '/bin/sh',
      arguments: const <String>['-c', 'sleep 30'],
      environment: const <String, String>{},
    );

    // flutter_pty only runs on supported platforms; on unsupported test hosts
    // this verifies graceful failure without polluting the active session list.
    if (!ok) {
      expect(PtySession.listActive(), isEmpty);
      return;
    }
    final id = session.id!;
    expect(PtySession.listActive().single['id'], id);
    await PtySession.closeActive(id);
    expect(PtySession.listActive(), isEmpty);
  });
}
