import 'dart:convert';

import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/tool_registry.dart';
import 'package:chronoxai/domain/plugins/builtin_plugins.dart';
import 'package:chronoxai/domain/plugins/plugin_api.dart';
import 'package:chronoxai/domain/plugins/plugin_runtime.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryFileSystem implements FileSystemSeam {
  final List<String> globPatterns = <String>[];
  final Map<String, String> files = <String, String>{};
  final Set<String> directories = <String>{'/workspace', '/workspace/test'};

  @override
  Future<bool> exists(String path) async =>
      files.containsKey(path) ||
      directories.contains(path) ||
      path == '/workspace/lib/main.dart';

  @override
  Future<List<String>> glob(String pattern) async {
    globPatterns.add(pattern);
    return <String>['/workspace/lib/main.dart'];
  }

  @override
  Future<List<String>> grep(String pattern, {String? path}) async =>
      const <String>[];

  @override
  Future<List<String>> list(String path) async =>
      <String>['$path/lib', '$path/README.md'];

  @override
  Future<String> readFile(String path) async => files[path] ?? 'void main() {}';

  @override
  Future<void> writeFile(String path, String content) async {
    files[path] = content;
  }
}

class _RecordingTerminals implements TerminalsSeam {
  String output = 'hello world';
  bool isAlive = true;

  @override
  Future<void> close(String terminalId) async {}

  @override
  Future<List<TerminalInfo>> list() async => <TerminalInfo>[
        TerminalInfo(
          id: 't1',
          title: 'test',
          isAlive: isAlive,
          bytesProduced: output.length,
        ),
      ];

  @override
  Future<String> open({String? title}) async => 't1';

  @override
  Future<String> read(String terminalId, {int? sinceOffset}) async {
    final offset = (sinceOffset ?? 0).clamp(0, output.length);
    return output.substring(offset);
  }

  @override
  Future<void> send(String terminalId, String input) async {}
}

class _RecordingShell implements ShellSeam {
  final List<String> commands = <String>[];
  final List<ShellResult> responses = <ShellResult>[];

  @override
  Future<ShellResult> run(
    String command, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    commands.add(command);
    return responses.isEmpty
        ? const ShellResult(exitCode: 0, stdout: 'ok', stderr: '')
        : responses.removeAt(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgentEventBus events;
  late ToolRegistry registry;
  late _MemoryFileSystem fileSystem;
  late _RecordingShell shell;
  late _RecordingTerminals terminals;
  late PluginHost host;

  setUp(() {
    events = AgentEventBus();
    registry = ToolRegistry();
    fileSystem = _MemoryFileSystem();
    shell = _RecordingShell();
    terminals = _RecordingTerminals();
    host = PluginHost(
      events: events,
      services: PluginServices(
        registry: registry,
        skills: <String, PluginSkill>{},
        modes: <String, PluginMode>{},
        surfaces: <String, PluginSurface>{},
        events: events,
        fileSystem: fileSystem,
        shell: shell,
        terminals: terminals,
      ),
    );
    for (final builtin in builtinPlugins()) {
      host.register(builtin.manifest, builtin.create());
    }
  });

  tearDown(() async => events.dispose());

  test('file tools list, check existence, and scope glob to a directory',
      () async {
    expect(await host.mount('core-fs'), isTrue);

    final listing = await registry.execute(
      'list_dir',
      <String, Object?>{'path': '/workspace'},
    );
    final exists = await registry.execute(
      'file_exists',
      <String, Object?>{'path': '/workspace/lib/main.dart'},
    );
    final matches = await registry.execute(
      'glob',
      <String, Object?>{'path': 'lib', 'pattern': '**/*.dart'},
    );

    expect(listing.content, contains('README.md'));
    expect(exists.content, contains('Existe'));
    expect(matches.content, contains('main.dart'));
    expect(fileSystem.globPatterns.single, '/workspace/lib/**/*.dart');
  });

  test('read_many combines bounded reads without failing other paths',
      () async {
    expect(await host.mount('core-fs'), isTrue);

    final result = await registry.execute(
      'read_many',
      <String, Object?>{
        'files': <String>['/workspace/a.dart', '/workspace/b.dart'],
        'offset': 1,
        'limit': 20,
      },
    );

    expect(result.content, contains('### /workspace/a.dart'));
    expect(result.content, contains('### /workspace/b.dart'));
    expect(result.content, contains('void main() {}'));
    expect(result.isError, isFalse);
  });

  test('terminal_read supports incremental offsets and reports process state',
      () async {
    expect(await host.mount('core-terminal'), isTrue);

    final chunk = await registry.execute(
      'terminal_read',
      <String, Object?>{'terminal_id': 't1', 'since_offset': 6},
    );
    expect(chunk.content, 'world');
    expect(chunk.metadata['next_offset'], 11);

    terminals.output = '';
    terminals.isAlive = false;
    final closed = await registry.execute(
      'terminal_read',
      <String, Object?>{'terminal_id': 't1', 'wait_ms': 0},
    );
    expect(closed.metadata['is_alive'], isFalse);
  });

  test('project_check runs only configured checks for detected Node projects',
      () async {
    fileSystem.files['/workspace/package.json'] = jsonEncode(<String, Object?>{
      'scripts': <String, String>{
        'test': 'jest',
        'lint': 'eslint .',
        'format:check': 'prettier --check .',
      },
    });
    expect(await host.mount('core-project-check'), isTrue);

    final result = await registry.execute(
      'project_check',
      const <String, Object?>{'suite': 'all'},
    );

    expect(result.isError, isFalse);
    expect(result.metadata['allPassed'], isTrue);
    expect(shell.commands, <String>[
      'npm test',
      'npm run lint',
      'npm run format:check',
    ]);
  });

  test('project_check refuses ambiguous monorepos without running commands',
      () async {
    fileSystem.files['/workspace/package.json'] = jsonEncode(
      <String, Object?>{
        'scripts': <String, String>{'test': 'jest'}
      },
    );
    fileSystem.files['/workspace/go.mod'] = 'module example.test/app';
    expect(await host.mount('core-project-check'), isTrue);

    final result = await registry.execute(
      'project_check',
      const <String, Object?>{'suite': 'tests'},
    );

    expect(result.isError, isTrue);
    expect(result.content, contains('varios ecosistemas'));
    expect(shell.commands, isEmpty);
  });

  test('editing records original state and rollback restores it', () async {
    fileSystem.files['/workspace/note.txt'] = 'before';
    expect(await host.mount('core-editing'), isTrue);

    final edited = await registry.execute('edit', <String, Object?>{
      'path': '/workspace/note.txt',
      'old_str': 'before',
      'new_str': 'after',
    });
    expect(edited.isError, isFalse);
    expect(fileSystem.files['/workspace/note.txt'], 'after');
    expect(registry['rollback_changes']!.requiresApproval, isTrue);

    final rolledBack = await registry.execute(
      'rollback_changes',
      const <String, Object?>{},
    );
    expect(rolledBack.isError, isFalse);
    expect(fileSystem.files['/workspace/note.txt'], 'before');
  });

  test('write tracks newly created files for explicit rollback', () async {
    expect(await host.mount('core-fs'), isTrue);
    expect(await host.mount('core-editing'), isTrue);

    final written = await registry.execute('write', <String, Object?>{
      'path': 'new-file.txt',
      'content': 'session content',
    });
    expect(written.isError, isFalse);
    expect(fileSystem.files['/workspace/new-file.txt'], 'session content');

    final rolledBack = await registry.execute(
      'rollback_changes',
      const <String, Object?>{},
    );
    expect(rolledBack.isError, isFalse);
    expect(
        shell.commands.single, contains("rm -f -- '/workspace/new-file.txt'"));
  });

  test('write rejects paths that escape the workspace', () async {
    expect(await host.mount('core-fs'), isTrue);
    final result = await registry.execute('write', <String, Object?>{
      'path': '../../outside.txt',
      'content': 'unsafe',
    });

    expect(result.isError, isTrue);
    expect(fileSystem.files.containsKey('/outside.txt'), isFalse);
  });

  test('patches preflight all listed paths before applying', () async {
    expect(await host.mount('core-editing'), isTrue);
    final patch = '--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old\n+new\n'
        '--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old\n+new';

    final result = await registry.execute(
      'apply_patch',
      <String, Object?>{'patch': patch},
    );

    expect(result.isError, isFalse);
    expect(shell.commands.first, contains('--dry-run'));
    expect(shell.commands[1], startsWith('patch -p1'));
    expect(result.metadata['files'], <String>[
      '/workspace/first.txt',
      '/workspace/second.txt',
    ]);
  });

  test('patch preflight failure never starts the mutating command', () async {
    expect(await host.mount('core-editing'), isTrue);
    shell.responses.add(
      const ShellResult(exitCode: 1, stdout: '', stderr: 'hunk failed'),
    );
    const patch = '--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new';

    final result = await registry.execute(
      'apply_patch',
      const <String, Object?>{'patch': patch},
    );

    expect(result.isError, isTrue);
    expect(shell.commands, hasLength(2));
    expect(shell.commands.first, contains('--dry-run'));
    expect(shell.commands.last, startsWith('rm -f --'));
    expect(fileSystem.files.keys, isNot(contains('/workspace/a.txt')));
  });

  test('git tools issue only fixed, read-only git commands', () async {
    expect(await host.mount('core-git'), isTrue);

    await registry.execute('git_status', const <String, Object?>{});
    await registry.execute('git_diff', <String, Object?>{'staged': true});
    await registry.execute('git_log', <String, Object?>{'limit': 4});

    expect(shell.commands, <String>[
      'git -C /workspace status --short --branch',
      'git -C /workspace diff --no-ext-diff --no-color --cached',
      'git -C /workspace log --oneline --decorate -n 4',
    ]);
  });
}
