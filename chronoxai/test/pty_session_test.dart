import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chronoxai/data/runtime/pty_session.dart';
import 'package:chronoxai/data/runtime/runtime_process_journal.dart';
import 'package:chronoxai/domain/terminal/control_keys.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePty implements PtyProcess {
  final StreamController<Uint8List> outputController =
      StreamController<Uint8List>();
  final Completer<int> exitCompleter = Completer<int>();
  final List<Uint8List> writes = <Uint8List>[];
  final List<(int, int)> sizes = <(int, int)>[];

  @override
  Stream<Uint8List> get output => outputController.stream;
  @override
  Future<int> get exitCode => exitCompleter.future;
  @override
  void write(final Uint8List data) => writes.add(data);
  @override
  void resize(final int rows, final int columns) => sizes.add((rows, columns));
  @override
  void ackRead() => acknowledgements++;

  int acknowledgements = 0;

  @override
  bool kill(final ProcessSignal signal) {
    if (!exitCompleter.isCompleted) exitCompleter.complete(0);
    return true;
  }
}

void main() {
  late FakePty process;
  late PtySession session;
  late Map<String, Object?> captured;

  setUp(() {
    process = FakePty();
    captured = <String, Object?>{};
    session = PtySession(
      command: 'proot → bash',
      processFactory: ({
        required final String executable,
        required final List<String> arguments,
        required final String workingDirectory,
        required final Map<String, String> environment,
        required final int rows,
        required final int columns,
      }) {
        captured.addAll(<String, Object?>{
          'executable': executable,
          'arguments': arguments,
          'workingDirectory': workingDirectory,
          'environment': environment,
          'rows': rows,
          'columns': columns,
        });
        return process;
      },
    );
  });

  tearDown(() async {
    await session.close();
    await process.outputController.close();
  });

  test('starts the process with exact args, cwd, environment and PTY size',
      () async {
    expect(
        await session.start(
          binary: '/data/app/lib/libproot.so',
          arguments: const <String>['--rootfs=/rootfs', '/bin/bash', '-l'],
          environment: const <String, String>{
            'LD_LIBRARY_PATH': '/data/app/lib'
          },
          workingDirectory: '/data/data/app/files',
          rows: 31,
          columns: 97,
        ),
        isTrue);

    expect(captured['executable'], '/data/app/lib/libproot.so');
    expect(
        captured['arguments'], <String>['--rootfs=/rootfs', '/bin/bash', '-l']);
    expect(captured['workingDirectory'], '/data/data/app/files');
    expect(captured['environment'],
        <String, String>{'LD_LIBRARY_PATH': '/data/app/lib'});
    expect(captured['rows'], 31);
    expect(captured['columns'], 97);
  });

  test('forwards PTY output and writes UTF-8 input bytes', () async {
    await session
        .start(binary: '/bin/sh', arguments: const [], environment: const {});
    final received = <Uint8List>[];
    session.output.listen(received.add);
    process.outputController.add(Uint8List.fromList('salud'.codeUnits));
    await session.write('ñ');
    await Future<void>.delayed(Duration.zero);
    expect(String.fromCharCodes(received.single), 'salud');
    expect(process.acknowledgements, 1);
    expect(process.writes.single, Uint8List.fromList(utf8.encode('ñ')));
  });

  test('writes control bytes and propagates window resize', () async {
    await session
        .start(binary: '/bin/sh', arguments: const [], environment: const {});
    await session.writeBytes(const <int>[3]);
    session.resize(40, 120);
    expect(process.writes.single, Uint8List.fromList(<int>[3]));
    expect(process.sizes, <(int, int)>[(40, 120)]);
  });

  test('close is idempotent, terminates the child, and removes it from registry',
      () async {
    await session.start(
      binary: '/bin/sh',
      arguments: const <String>[],
      environment: const <String, String>{},
    );

    await session.close();
    await session.close();

    expect(session.state, PtyState.exited);
    expect(session.exitCode, 0);
    expect(await session.write('ignored'), isFalse);
    expect(PtySession.listActive(), isEmpty);
  });

  test('publishes logical id, timing and exit status to process journal',
      () async {
    final temp = await Directory.systemTemp.createTemp('chronox-pty-journal-');
    final journal = await RuntimeProcessJournal.open(temp.path);
    final journaledSession = PtySession(
      command: 'journal-test',
      journal: journal,
      processFactory: ({
        required final String executable,
        required final List<String> arguments,
        required final String workingDirectory,
        required final Map<String, String> environment,
        required final int rows,
        required final int columns,
      }) => process,
    );
    try {
      await journaledSession.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );
      final processId = journaledSession.id;
      expect(processId, isNotNull);
      expect(journaledSession.startedAt, isNotNull);
      expect(journal.records.single.state, RuntimeProcessState.running);
      process.outputController.add(Uint8List.fromList('hello'.codeUnits));
      process.exitCompleter.complete(13);
      await Future<void>.delayed(Duration.zero);
      await journal.flush();

      expect(journaledSession.exitCode, 13);
      expect(journaledSession.outputBytesProduced, 5);
      expect(journaledSession.duration, isNotNull);
      expect(journal.records.single.state, RuntimeProcessState.exited);
      expect(journal.records.single.exitCode, 13);
      expect(journal.records.single.outputBytes, 5);
    } finally {
      await journaledSession.close();
      await temp.delete(recursive: true);
    }
  });

  test('exit event is published and session is removed from active list',
      () async {
    await session
        .start(binary: '/bin/sh', arguments: const [], environment: const {});
    final codes = <int>[];
    session.exit.listen(codes.add);
    process.exitCompleter.complete(7);
    await Future<void>.delayed(Duration.zero);
    expect(codes, <int>[7]);
    expect(session.state, PtyState.exited);
    expect(session.exitCode, 7);
    expect(session.startedAt, isNotNull);
    expect(session.exitedAt, isNotNull);
    expect(session.duration, isNotNull);
    expect(PtySession.listActive(), isEmpty);
  });
}
