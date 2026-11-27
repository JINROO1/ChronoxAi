import 'dart:io';

import 'package:chronoxai/domain/agent/hook_runner.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:flutter_test/flutter_test.dart';

class _Shell implements ShellSeam {
  final commands = <String>[];
  final timeouts = <Duration?>[];
  final codes = <int>[];

  @override
  Future<ShellResult> run(String command,
      {String? workingDirectory, Duration? timeout}) async {
    commands.add(command);
    timeouts.add(timeout);
    final code = codes.isEmpty ? 0 : codes.removeAt(0);
    return ShellResult(exitCode: code, stdout: '', stderr: 'hook failure');
  }
}

void main() {
  late Directory dir;
  late _Shell shell;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chronox-hooks-');
    shell = _Shell();
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('carga hooks desde .chronox/hooks.json y pasa contexto quotado',
      () async {
    final file = File('${dir.path}/.chronox/hooks.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('''
{"hooks":{"on_tool_call":[{"command":"printf hook","blocking":true,"timeoutMs":2500}]}}
''');
    final hooks = await HookRunner.load(workspace: dir, shell: shell);

    final result = await hooks!.run(
      HookPoint.onToolCall,
      context: <String, String>{'CHRONOX_TOOL_NAME': "read 'a'"},
    );

    expect(result.blocked, isFalse);
    expect(shell.commands.single,
        contains("CHRONOX_TOOL_NAME='read '\\''a'\\'''"));
    expect(shell.timeouts.single, const Duration(milliseconds: 2500));
  });

  test('un hook non-cero bloquea solo si blocking=true', () async {
    final hooks = HookRunner(
      shell: shell,
      hooks: <HookPoint, List<HookSpec>>{
        HookPoint.onToolCall: const <HookSpec>[
          HookSpec(command: 'check', blocking: true),
        ],
      },
    );
    shell.codes.add(9);

    final result = await hooks.run(HookPoint.onToolCall);

    expect(result.blocked, isTrue);
    expect(result.message, 'hook failure');
  });

  test('un fallo de hook no bloqueante no detiene al agente', () async {
    final hooks = HookRunner(
      shell: shell,
      hooks: <HookPoint, List<HookSpec>>{
        HookPoint.onTurnStart: const <HookSpec>[HookSpec(command: 'log')],
      },
    );
    shell.codes.add(2);

    expect((await hooks.run(HookPoint.onTurnStart)).blocked, isFalse);
  });
}
