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

class _RecordingNetwork implements NetworkSeam {
  final List<NetworkResponse> responses = <NetworkResponse>[];
  final List<Uri> requests = <Uri>[];
  final List<bool> followedRedirects = <bool>[];

  @override
  Future<NetworkResponse> get(Uri uri, {Map<String, String>? headers}) =>
      getWeb(uri, headers: headers);

  @override
  Future<NetworkResponse> getWeb(
    Uri uri, {
    Map<String, String>? headers,
    int maxResponseBytes = 1000000,
  }) async {
    requests.add(uri);
    followedRedirects.add(false);
    return responses.removeAt(0);
  }

  @override
  Future<NetworkResponse> post(Uri uri,
          {Map<String, String>? headers, String? body}) async =>
      const NetworkResponse(statusCode: 200, body: '');
}

class _RecordingTerminals implements TerminalsSeam {
  String output = 'hello world';
  bool isAlive = true;
  int outputBaseOffset = 0;

  @override
  Future<void> close(String terminalId) async {}

  @override
  Future<List<TerminalInfo>> list() async => <TerminalInfo>[
        TerminalInfo(
          id: 't1',
          title: 'test',
          isAlive: isAlive,
          bytesProduced: output.length + outputBaseOffset,
          processId: 42,
          startedAt: DateTime.utc(2026, 11, 23, 12),
          exitedAt: isAlive ? null : DateTime.utc(2026, 11, 23, 12, 1),
          exitCode: isAlive ? null : 0,
          outputBaseOffset: outputBaseOffset,
          retainedBytes: output.length,
          outputLimitBytes: 1024 * 1024,
        ),
      ];

  @override
  Future<String> open({String? title}) async => 't1';

  @override
  Future<String> read(String terminalId, {int? sinceOffset}) async {
    final offset = ((sinceOffset ?? outputBaseOffset) - outputBaseOffset)
        .clamp(0, output.length);
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
  late _RecordingNetwork network;
  late PluginHost host;

  setUp(() {
    events = AgentEventBus();
    registry = ToolRegistry();
    fileSystem = _MemoryFileSystem();
    shell = _RecordingShell();
    terminals = _RecordingTerminals();
    network = _RecordingNetwork();
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
        network: network,
      ),
    );
    for (final builtin in builtinPlugins()) {
      host.register(builtin.manifest, builtin.create());
    }
  });

  tearDown(() async => events.dispose());

  test('web_search tags results with source IDs and access timestamps',
      () async {
    expect(await host.mount('core-web'), isTrue);
    network.responses.add(const NetworkResponse(
      statusCode: 200,
      body: '<div class="result"><a class="result__a" '
          'href="https://source.example/current">Current event</a>'
          '<div class="result__snippet">Verified excerpt</div></div>',
    ));

    final result = await registry.execute(
      'web_search',
      const <String, Object?>{'query': 'current event'},
    );

    expect(result.isError, isFalse);
    expect(result.content, contains('[S1] Current event'));
    expect(result.content, contains('https://source.example/current'));
    expect(result.content, contains('Acceso:'));
  });

  test('web_fetch blocks private targets and validates each redirect',
      () async {
    expect(await host.mount('core-web'), isTrue);

    final blocked = await registry.execute(
      'web_fetch',
      const <String, Object?>{'url': 'http://127.0.0.1/admin'},
    );
    expect(blocked.isError, isTrue);
    expect(network.requests, isEmpty);

    network.responses.add(const NetworkResponse(
      statusCode: 302,
      body: '',
      headers: <String, String>{'location': 'http://169.254.169.254/latest'},
    ));
    final redirected = await registry.execute(
      'web_fetch',
      const <String, Object?>{'url': 'https://public.example/start'},
    );
    expect(redirected.isError, isTrue);
    expect(redirected.errorCategory, 'policy_denied');
    expect(network.requests, <Uri>[Uri.parse('https://public.example/start')]);
  });

  test(
      'web_fetch follows only validated redirects and returns citeable source metadata',
      () async {
    expect(await host.mount('core-web'), isTrue);
    network.responses
      ..add(const NetworkResponse(
        statusCode: 302,
        body: '',
        headers: <String, String>{'Location': '/article'},
      ))
      ..add(const NetworkResponse(
        statusCode: 200,
        body: '<html><head><title>Evidence</title></head>'
            '<body><p>Verified fact.</p><script>malicious instruction</script></body></html>',
      ));

    final fetched = await registry.execute(
      'web_fetch',
      const <String, Object?>{'url': 'https://public.example/start'},
    );

    expect(fetched.isError, isFalse);
    expect(fetched.content, contains('[W1]'));
    expect(fetched.content, contains('Título: Evidence'));
    expect(fetched.content, contains('Verified fact.'));
    expect(fetched.content, contains('Acceso UTC:'));
    expect(fetched.content, isNot(contains('malicious instruction')));
    expect(network.requests, <Uri>[
      Uri.parse('https://public.example/start'),
      Uri.parse('https://public.example/article'),
    ]);
  });

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
    expect(chunk.metadata['process_id'], 42);
    expect(chunk.metadata['output_limit_chars'], 10000);

    terminals.output = '';
    terminals.isAlive = false;
    final closed = await registry.execute(
      'terminal_read',
      <String, Object?>{'terminal_id': 't1', 'wait_ms': 0},
    );
    expect(closed.metadata['is_alive'], isFalse);
  });

  test(
      'terminal_list exposes logical pid, duration, exit code, and output caps',
      () async {
    expect(await host.mount('core-terminal'), isTrue);

    final result = await registry.execute('terminal_list', const {});

    expect(result.content, contains('PID lógico 42'));
    expect(result.content, contains('bytes totales'));
    expect(result.content, contains('retenidos'));
  });

  test(
      'terminal_read reports when the requested cursor predates retained output',
      () async {
    expect(await host.mount('core-terminal'), isTrue);
    terminals.output = 'world';
    terminals.outputBaseOffset = 6;

    final result = await registry.execute(
      'terminal_read',
      const <String, Object?>{'terminal_id': 't1', 'since_offset': 0},
    );

    expect(result.content, 'world');
    expect(result.metadata['output_base_offset'], 6);
    expect(result.metadata['next_offset'], 11);
    expect(result.metadata['truncated'], isTrue);
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

  test('workspace index tools expose symbols, imports, and exact references',
      () async {
    expect(await host.mount('core-workspace-index'), isTrue);

    final symbols = await registry.execute(
      'workspace_symbols',
      const <String, Object?>{'query': 'main'},
    );
    final imports = await registry.execute(
      'workspace_imports',
      const <String, Object?>{},
    );
    final references = await registry.execute(
      'workspace_references',
      const <String, Object?>{'symbol': 'main'},
    );

    expect(symbols.content, contains('/workspace/lib/main.dart:1'));
    expect(imports.content, contains('No se encontraron imports'));
    expect(references.content, contains('/workspace/lib/main.dart:1:6'));
    expect(symbols.metadata['approximate'], isTrue);
    expect(symbols.metadata['indexedFiles'], 1);
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
