import 'dart:async';
import 'dart:convert';

import '../../domain/plugins/seams.dart';
import 'local_runtime.dart';
import 'pty_session.dart';
import 'runtime_process_journal.dart';

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
    final journal = await RuntimeProcessJournal.open(runtime.paths.sessionsDir);
    final session = PtySession(
      command: title ?? 'Terminal del agente',
      journal: journal,
    );
    final output = <int>[];
    var totalBytes = 0;
    var outputBaseOffset = 0;
    var alive = true;
    final outputSubscription = session.output.listen((final chunk) {
      totalBytes += chunk.length;
      output.addAll(chunk);
      if (output.length > _AgentTerminal.maxOutputBytes) {
        final normalized = utf8.encode(utf8.decode(output, allowMalformed: true));
        var bytesToDrop = normalized.length - _AgentTerminal.maxOutputBytes;
        while (bytesToDrop < normalized.length &&
            (normalized[bytesToDrop] & 0xc0) == 0x80) {
          bytesToDrop++;
        }
        outputBaseOffset += utf8
            .decode(normalized.sublist(0, bytesToDrop), allowMalformed: true)
            .length;
        output
          ..clear()
          ..addAll(normalized.skip(bytesToDrop));
      }
    });
    final exitSubscription = session.exit.listen((final _) => alive = false);
    final ok = await session.start(
      binary: command.binary,
      arguments: command.args,
      environment: command.env,
      workingDirectory: runtime.paths.filesDir,
    );
    if (!ok) {
      await outputSubscription.cancel();
      await exitSubscription.cancel();
      await session.close();
      throw const RuntimeException('No se pudo abrir el PTY del agente.');
    }
    final id = 'agent-${_nextId++}';
    _sessions[id] = _AgentTerminal(
      id: id,
      title: title ?? 'Terminal del agente',
      session: session,
      output: output,
      totalBytesProduced: () => totalBytes,
      outputBaseOffset: () => outputBaseOffset,
      outputSubscription: outputSubscription,
      exitSubscription: exitSubscription,
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
    final offset = ((sinceOffset ?? terminal.outputBaseOffset()) -
            terminal.outputBaseOffset())
        .clamp(0, text.length);
    return text.substring(offset);
  }

  @override
  Future<void> close(final String terminalId) async {
    final terminal = _sessions.remove(terminalId);
    if (terminal == null) return;
    await terminal.outputSubscription.cancel();
    await terminal.exitSubscription.cancel();
    await terminal.session.close();
  }

  @override
  Future<List<TerminalInfo>> list() async => _sessions.values
      .map((final terminal) => TerminalInfo(
            id: terminal.id,
            title: terminal.title,
            isAlive: terminal.isAlive(),
            bytesProduced: terminal.totalBytesProduced(),
            processId: terminal.session.id,
            startedAt: terminal.session.startedAt,
            exitedAt: terminal.session.exitedAt,
            exitCode: terminal.session.exitCode,
            outputBaseOffset: terminal.outputBaseOffset(),
            retainedBytes: terminal.output.length,
            outputLimitBytes: _AgentTerminal.maxOutputBytes,
          ))
      .toList(growable: false);

  _AgentTerminal _require(final String id) =>
      _sessions[id] ?? (throw StateError('No existe la terminal $id.'));
}

class _AgentTerminal {
  static const int maxOutputBytes = 1024 * 1024;

  const _AgentTerminal({
    required this.id,
    required this.title,
    required this.session,
    required this.output,
    required this.totalBytesProduced,
    required this.outputBaseOffset,
    required this.outputSubscription,
    required this.exitSubscription,
    required this.isAlive,
  });

  final String id;
  final String title;
  final PtySession session;
  final List<int> output;
  final int Function() totalBytesProduced;
  final int Function() outputBaseOffset;
  final StreamSubscription<List<int>> outputSubscription;
  final StreamSubscription<int> exitSubscription;
  final bool Function() isAlive;
}
