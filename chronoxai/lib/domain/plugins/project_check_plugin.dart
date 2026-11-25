import 'dart:convert';

import 'plugin_api.dart';

/// Runs bounded, read-only verification commands chosen from project metadata.
/// It deliberately never installs dependencies or accepts arbitrary commands.
class ProjectCheckPlugin extends ChronoxPlugin {
  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'project_check',
        description:
            'Detecta el ecosistema del workspace y ejecuta tests, análisis '
            'estático y/o comprobación de formato. Solo usa comandos conocidos, '
            'no instala dependencias y devuelve cada resultado por separado. '
            'Si el repositorio mezcla varios ecosistemas, indica `ecosystem`.',
        requiresApproval: true,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'suite': <String, Object?>{
              'type': 'string',
              'enum': <String>['tests', 'analyze', 'format', 'all'],
              'description': 'Comprobación a ejecutar; por defecto all.',
            },
            'ecosystem': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'auto',
                'flutter',
                'dart',
                'node',
                'python',
                'go',
                'rust',
              ],
              'description': 'Forzar el ecosistema en un monorepo.',
            },
            'timeout_ms': <String, Object?>{
              'type': 'integer',
              'description': 'Timeout por comprobación (10–900 s).',
            },
          },
          'required': <String>[],
          'additionalProperties': false,
        },
        execute: (final args) async {
          final fs = context.services.fileSystem;
          final shell = context.services.shell;
          final suite = (args['suite'] as String?) ?? 'all';
          final requestedEcosystem = (args['ecosystem'] as String?) ?? 'auto';
          final timeoutMs = ((args['timeout_ms'] as int?) ?? 300000)
              .clamp(10000, 900000);

          final detection = await _detect(fs);
          if (requestedEcosystem == 'auto' && detection.found.isEmpty) {
            return const ToolOutcome.error(
              'No se reconoció un proyecto compatible (Flutter/Dart, Node, '
              'Python, Go o Rust). No se ejecutó ningún comando.',
            );
          }
          if (requestedEcosystem == 'auto' && detection.found.length > 1) {
            return ToolOutcome.error(
              'Hay varios ecosistemas en /workspace: '
              '${detection.found.join(', ')}. Indica ecosystem para elegir '
              'explícitamente; no se ejecutó ningún comando.',
            );
          }
          final ecosystem = requestedEcosystem == 'auto'
              ? detection.found.first
              : requestedEcosystem;
          if (!detection.found.contains(ecosystem)) {
            return ToolOutcome.error(
              'No se detectó el ecosistema "$ecosystem". Detectados: '
              '${detection.found.isEmpty ? '(ninguno)' : detection.found.join(', ')}.',
            );
          }

          final checks = await _commandsFor(fs, ecosystem, suite);
          if (checks.isEmpty) {
            return ToolOutcome.error(
              'No hay comprobaciones configuradas para $ecosystem/$suite. '
              'No se inventó ni ejecutó un comando.',
            );
          }

          final results = <Map<String, Object?>>[];
          final sections = <String>[];
          for (final check in checks) {
            if (check.command == null) {
              sections.add('${check.name}: OMITIDA — ${check.skipReason}');
              results.add(<String, Object?>{
                'name': check.name,
                'status': 'skipped',
                'reason': check.skipReason,
              });
              continue;
            }
            try {
              final result = await shell.run(
                check.command!,
                workingDirectory: '/workspace',
                timeout: Duration(milliseconds: timeoutMs),
              );
              final rawOutput = result.output.trim();
              const maxOutput = 3000;
              final clipped = rawOutput.length > maxOutput
                  ? '${rawOutput.substring(0, maxOutput)}\n[salida limitada; '
                      'se omitieron ${rawOutput.length - maxOutput} caracteres]'
                  : rawOutput;
              final status = result.isSuccess ? 'PASS' : 'FAIL';
              sections.add(
                '### ${check.name}: $status (exit ${result.exitCode})'
                '${clipped.isEmpty ? '' : '\n$clipped'}',
              );
              results.add(<String, Object?>{
                'name': check.name,
                'status': result.isSuccess ? 'passed' : 'failed',
                'exitCode': result.exitCode,
                'outputTruncated': rawOutput.length > maxOutput,
              });
            } catch (error) {
              sections.add('### ${check.name}: ERROR\n$error');
              results.add(<String, Object?>{
                'name': check.name,
                'status': 'error',
                'error': error.toString(),
              });
            }
          }

          final hasFailure = results.any(
            (final result) =>
                result['status'] == 'failed' || result['status'] == 'error',
          );
          return ToolOutcome(
            content: 'Proyecto: $ecosystem\n'
                '${sections.join('\n\n')}',
            isError: hasFailure,
            metadata: <String, Object?>{
              'ecosystem': ecosystem,
              'suite': suite,
              'checks': results,
              'allPassed': !hasFailure &&
                  results.every((final result) => result['status'] == 'passed'),
            },
          );
        },
      ),
    );
  }

  static Future<_Detection> _detect(final FileSystemSeam fs) async {
    final found = <String>[];
    if (await fs.exists('/workspace/pubspec.yaml')) {
      final pubspec = await fs.readFile('/workspace/pubspec.yaml');
      final isFlutter = RegExp(r'(?m)^\s*flutter_test\s*:').hasMatch(pubspec) ||
          RegExp(r'(?m)^\s*flutter\s*:\s*$').hasMatch(pubspec);
      found.add(isFlutter ? 'flutter' : 'dart');
    }
    if (await fs.exists('/workspace/package.json')) found.add('node');
    if (await fs.exists('/workspace/pyproject.toml') ||
        await fs.exists('/workspace/pytest.ini') ||
        await fs.exists('/workspace/setup.py')) {
      found.add('python');
    }
    if (await fs.exists('/workspace/go.mod')) found.add('go');
    if (await fs.exists('/workspace/Cargo.toml')) found.add('rust');
    return _Detection(found: found);
  }

  static Future<List<_Check>> _commandsFor(
    final FileSystemSeam fs,
    final String ecosystem,
    final String suite,
  ) async {
    final requested = switch (suite) {
      'tests' => const <String>['tests'],
      'analyze' => const <String>['analyze'],
      'format' => const <String>['format'],
      'all' => const <String>['tests', 'analyze', 'format'],
      _ => const <String>[],
    };
    if (requested.isEmpty) return <_Check>[];

    final commands = <String, String?>{};
    final reasons = <String, String>{};
    final hasTestDir = await fs.exists('/workspace/test');
    final dartTargets = <String>[
      if (await fs.exists('/workspace/lib')) 'lib',
      if (hasTestDir) 'test',
    ];
    final dartFormat = dartTargets.isEmpty
        ? null
        : 'dart format --output=none --set-exit-if-changed '
            '${dartTargets.join(' ')}';
    switch (ecosystem) {
      case 'flutter':
        commands.addAll(<String, String?>{
          'tests': hasTestDir ? 'flutter test' : null,
          'analyze': 'flutter analyze',
          'format': dartFormat,
        });
        if (!hasTestDir) reasons['tests'] = 'no existe /workspace/test';
        if (dartFormat == null) reasons['format'] = 'no hay lib/ ni test/';
      case 'dart':
        commands.addAll(<String, String?>{
          'tests': hasTestDir ? 'dart test' : null,
          'analyze': 'dart analyze',
          'format': dartFormat,
        });
        if (!hasTestDir) reasons['tests'] = 'no existe /workspace/test';
        if (dartFormat == null) reasons['format'] = 'no hay lib/ ni test/';
      case 'node':
        final package = jsonDecode(
          await fs.readFile('/workspace/package.json'),
        );
        final scripts = package is Map<String, dynamic>
            ? package['scripts'] as Map<String, dynamic>? ??
                const <String, dynamic>{}
            : const <String, dynamic>{};
        final manager = await fs.exists('/workspace/pnpm-lock.yaml')
            ? 'pnpm'
            : await fs.exists('/workspace/yarn.lock')
                ? 'yarn'
                : 'npm';
        commands['tests'] = scripts.containsKey('test') ? '$manager test' : null;
        commands['analyze'] = scripts.containsKey('lint')
            ? '$manager run lint'
            : scripts.containsKey('typecheck')
                ? '$manager run typecheck'
                : null;
        commands['format'] = scripts.containsKey('format:check')
            ? '$manager run format:check'
            : null;
        reasons['tests'] = 'package.json no define scripts.test';
        reasons['analyze'] = 'no existe scripts.lint ni scripts.typecheck';
        reasons['format'] = 'no existe scripts.format:check';
      case 'python':
        final pyprojectExists = await fs.exists('/workspace/pyproject.toml');
        final pyproject = pyprojectExists
            ? await fs.readFile('/workspace/pyproject.toml')
            : '';
        final hasRuff = pyproject.contains('[tool.ruff]') ||
            await fs.exists('/workspace/ruff.toml') ||
            await fs.exists('/workspace/.ruff.toml');
        commands.addAll(<String, String?>{
          'tests': 'python3 -m pytest -q',
          'analyze': hasRuff ? 'ruff check .' : null,
          'format': hasRuff ? 'ruff format --check .' : null,
        });
        reasons['analyze'] = 'no se configuró Ruff';
        reasons['format'] = 'no se configuró Ruff';
      case 'go':
        commands.addAll(<String, String?>{
          'tests': 'go test ./...',
          'analyze': 'go vet ./...',
          'format': "files=\$(gofmt -l .); if [ -n \"\$files\" ]; then printf '%s\\n' \"\$files\"; exit 1; fi",
        });
      case 'rust':
        commands.addAll(<String, String?>{
          'tests': 'cargo test --workspace',
          'analyze': 'cargo clippy --all-targets --all-features -- -D warnings',
          'format': 'cargo fmt --all -- --check',
        });
      default:
        return <_Check>[];
    }
    return requested
        .map(
          (final name) => _Check(
            name: name,
            command: commands[name],
            skipReason: reasons[name] ?? 'no configurado',
          ),
        )
        .toList();
  }
}

class _Detection {
  const _Detection({required this.found});

  final List<String> found;
}

class _Check {
  const _Check({
    required this.name,
    required this.command,
    required this.skipReason,
  });

  final String name;
  final String? command;
  final String skipReason;
}
