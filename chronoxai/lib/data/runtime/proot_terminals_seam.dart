import 'dart:async';
import 'dart:convert';

import '../../domain/plugins/seams.dart';
import 'local_runtime.dart';
import 'pty_session.dart';

/// Adapta sesiones PTY persistentes a las herramientas terminal_* del agente.
/// Las sesiones usan el mismo PRoot, rootfs y /workspace que la terminal de UI,
/// aunque cada terminal_open crea un proceso PTY independiente.
class ProotTerminalsSeam implements TerminalsSeam {
  ProotTerminalsSeam(this.runtime);

  final LocalRuntime runtime;
  final Map<String, _AgentTerminal> _sessions = <String, _AgentTerminal>{};
  int _nextId = 1;

  @override
  Future<String> open({String? title}) async {
    final status = await runtime.status();
    if (!status.isReady) {
      throw RuntimeException('${status.title}: ${status.message}');
    }
    final command = await runtime.interactiveCommand(
      workingDirectory: LocalRuntime.guestWorkspace,
    );
    final session = PtySession(command: title ?? 'Terminal del agente');
    final output = <int>[];
    var alive = true;
    final subscription = session.output.listen((final chunk) {
      output.addAll(chunk);
      // Limita el scrollback residente para que una sesión larga no agote RAM.
      if (output.length > 1024 * 1024) {
        output.removeRange(0, output.length - 1024 * 1024);
      }
    });
    session.exit.listen((final _) => alive = false);
    final ok = await session.start(
      binary: command.binary,
      arguments: command.args,
      environment: command.env,
      workingDirectory: runtime.paths.filesDir,
    );
    if (!ok) {
      await subscription.cancel();
      throw const RuntimeException('No se pudo abrir el PTY del agente.');
    }
    final id = 'agent-${_nextId++}';
    _sessions[id] = _AgentTerminal(
      id: id,
      title: title ?? 'Terminal del agente',
      session: session,
      output: output,
      subscription: subscription,
      isAlive: () => alive,
    );
    return id;
  }

  @override
  Future<void> send(final String terminalId, final String input) async {
    final terminal = _require(terminalId);
    if (!terminal.isAlive()) {
      throw StateError('La terminal $terminalId ya terminó.');
    }
    if (!await terminal.session.write(input)) {
      throw StateError('No se pudo escribir en la terminal $terminalId.');
    }
  }

  @override
  Future<String> read(final String terminalId, {final int? sinceOffset}) async {
    final terminal = _require(terminalId);
    final text = utf8.decode(terminal.output, allowMalformed: true);
    final offset = (sinceOffset ?? 0).clamp(0, text.length);
    return text.substring(offset);
  }

  @override
  Future<void> close(final String terminalId) async {
    final terminal = _sessions.remove(terminalId);
    if (terminal == null) return;
    await terminal.subscription.cancel();
    await terminal.session.close();
  }

  @override
  Future<List<TerminalInfo>> list() async => _sessions.values
      .map((final terminal) => TerminalInfo(
            id: terminal.id,
            title: terminal.title,
            isAlive: terminal.isAlive(),
            bytesProduced: terminal.output.length,
          ))
      .toList(growable: false);

  _AgentTerminal _require(final String id) =>
      _sessions[id] ?? (throw StateError('No existe la terminal $id.'));
}

class _AgentTerminal {
  const _AgentTerminal({
    required this.id,
    required this.title,
    required this.session,
    required this.output,
    required this.subscription,
    required this.isAlive,
  });

  final String id;
  final String title;
  final PtySession session;
  final List<int> output;
  final StreamSubscription<List<int>> subscription;
  final bool Function() isAlive;
}
