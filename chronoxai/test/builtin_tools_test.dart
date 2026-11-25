import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/tool_registry.dart';
import 'package:chronoxai/domain/plugins/builtin_plugins.dart';
import 'package:chronoxai/domain/plugins/plugin_api.dart';
import 'package:chronoxai/domain/plugins/plugin_runtime.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryFileSystem implements FileSystemSeam {
  final List<String> globPatterns = <String>[];

  @override
  Future<bool> exists(String path) async => path == '/workspace/lib/main.dart';

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
  Future<String> readFile(String path) async => 'void main() {}';

  @override
  Future<void> writeFile(String path, String content) async {}
}

class _RecordingShell implements ShellSeam {
  final List<String> commands = <String>[];

  @override
  Future<ShellResult> run(
    String command, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    commands.add(command);
    return const ShellResult(exitCode: 0, stdout: 'ok', stderr: '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgentEventBus events;
  late ToolRegistry registry;
  late _MemoryFileSystem fileSystem;
  late _RecordingShell shell;
  late PluginHost host;

  setUp(() {
    events = AgentEventBus();
    registry = ToolRegistry();
    fileSystem = _MemoryFileSystem();
    shell = _RecordingShell();
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
