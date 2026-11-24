import 'dart:convert';
import 'dart:io';

import '../plugins/seams.dart';

/// Puntos de extensión soportados por `.chronox/hooks.json`.
enum HookPoint {
  onTurnStart('on_turn_start'),
  onTurnEnd('on_turn_end'),
  onToolCall('on_tool_call'),
  onToolResult('on_tool_result'),
  onApprovalRequest('on_approval_request');

  const HookPoint(this.jsonName);
  final String jsonName;

  static HookPoint? parse(final String value) {
    for (final point in values) {
      if (point.jsonName == value) return point;
    }
    return null;
  }
}

class HookSpec {
  const HookSpec({
    required this.command,
    this.blocking = false,
    this.timeout = const Duration(seconds: 10),
  });

  final String command;
  final bool blocking;
  final Duration timeout;
}

class HookRunResult {
  const HookRunResult({this.blocked = false, this.message = ''});
  final bool blocked;
  final String message;
}

/// Lee y ejecuta hooks del workspace dentro del shell del runtime.
///
/// Formato: `{"hooks":{"on_tool_call":[{"command":"...","blocking":true,"timeoutMs":5000}]}}`.
/// Los hooks no bloquean salvo que `blocking` se marque explícitamente.
class HookRunner {
  HookRunner({required this.shell, required this.hooks});

  final ShellSeam shell;
  final Map<HookPoint, List<HookSpec>> hooks;

  static Future<HookRunner?> load({
    required final Directory workspace,
    required final ShellSeam shell,
  }) async {
    final candidates = <File>[
      File('${workspace.path}/.chronox/hooks.json'),
      File('${workspace.path}/hooks.json'),
    ];
    for (final file in candidates) {
      try {
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('La raíz de hooks.json debe ser un objeto.');
        }
        final source = decoded['hooks'];
        if (source is! Map<String, Object?>) {
          throw const FormatException('hooks.json necesita el objeto "hooks".');
        }
        final hooks = <HookPoint, List<HookSpec>>{};
        for (final entry in source.entries) {
          final point = HookPoint.parse(entry.key);
          if (point == null) continue;
          if (entry.value is! List) continue;
          final specs = <HookSpec>[];
          for (final raw in entry.value as List<Object?>) {
            if (raw is String) {
              specs.add(HookSpec(command: raw));
            } else if (raw is Map<String, Object?> && raw['command'] is String) {
              final timeoutMs = (raw['timeoutMs'] as num?)?.toInt() ?? 10000;
              specs.add(HookSpec(
                command: raw['command']! as String,
                blocking: raw['blocking'] == true,
                timeout: Duration(milliseconds: timeoutMs.clamp(100, 120000).toInt()),
              ));
            }
          }
          hooks[point] = List<HookSpec>.unmodifiable(specs);
        }
        return HookRunner(shell: shell, hooks: Map.unmodifiable(hooks));
      } on FormatException {
        rethrow;
      } catch (_) {
        // I/O transitorio: se intenta la siguiente ubicación; el agente sigue
        // siendo útil incluso si el workspace no permite leer hooks.json.
      }
    }
    return null;
  }

  Future<HookRunResult> run(
    final HookPoint point, {
    Map<String, String> context = const <String, String>{},
  }) async {
    for (final hook in hooks[point] ?? const <HookSpec>[]) {
      final assignments = context.entries
          .map((final entry) => '${entry.key}=${_quote(entry.value)}')
          .join(' ');
      final command = assignments.isEmpty
          ? hook.command
          : '$assignments ${hook.command}';
      try {
        final result = await shell.run(
          command,
          workingDirectory: '/workspace',
          timeout: hook.timeout,
        );
        if (result.exitCode != 0 && hook.blocking) {
          return HookRunResult(
            blocked: true,
            message: result.stderr.trim().isEmpty
                ? 'Hook ${point.jsonName} bloqueó la acción (exit ${result.exitCode}).'
                : result.stderr.trim(),
          );
        }
      } catch (error) {
        if (hook.blocking) {
          return HookRunResult(
            blocked: true,
            message: 'No se pudo ejecutar el hook ${point.jsonName}: $error',
          );
        }
      }
    }
    return const HookRunResult();
  }

  static String _quote(final String value) => "'${value.replaceAll("'", "'\\''")}'";
}
