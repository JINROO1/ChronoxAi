import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Transporte JSON-RPC line-delimited para plugins externos.
abstract interface class ExternalPluginTransport {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  void sendLine(String line);
  Future<void> close();
}

/// Adaptador de stdin/stdout de un proceso iniciado en el contenedor proot.
class ProcessPluginTransport implements ExternalPluginTransport {
  ProcessPluginTransport(this.process)
      : stdoutLines = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
        stderrLines = process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter()) {
    // Siempre drenar stderr para evitar que un plugin ruidoso bloquee el pipe.
    stderrLines.listen((final _) {});
  }

  final Process process;

  @override
  final Stream<String> stdoutLines;
  @override
  final Stream<String> stderrLines;

  @override
  void sendLine(final String line) {
    process.stdin.writeln(line);
    process.stdin.flush();
  }

  @override
  Future<void> close() async {
    try {
      process.stdin.writeln(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'params': <String, Object?>{},
      }));
      await process.stdin.flush().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
    }
  }
}

/// Multiplexa solicitudes JSON-RPC 2.0 sobre una línea por mensaje.
class ExternalPluginRpc {
  ExternalPluginRpc(this.transport) {
    _subscription = transport.stdoutLines.listen(
      _receive,
      onError: (final Object error, final StackTrace stack) => _failAll(error),
      onDone: () => _failAll(const ExternalPluginException('plugin terminó')),
    );
  }

  final ExternalPluginTransport transport;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  late final StreamSubscription<String> _subscription;
  int _nextId = 0;
  bool _closed = false;

  Future<Map<String, Object?>> request(
    final String method,
    final Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed) throw const ExternalPluginException('plugin cerrado');
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    transport.sendLine(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw ExternalPluginException('timeout en plugin: $method');
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _failAll(const ExternalPluginException('plugin cerrado'));
    await transport.close();
  }

  void _receive(final String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final message = decoded.cast<String, Object?>();
      final id = (message['id'] as num?)?.toInt();
      if (id == null) return; // notification/log line: no response expected.
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final rpcError = message['error'];
      if (rpcError is Map) {
        final error = rpcError.cast<Object?, Object?>();
        completer.completeError(ExternalPluginException(
          '${error['code'] ?? ''}: ${error['message'] ?? 'JSON-RPC error'}',
        ));
      } else {
        final result = message['result'];
        completer.complete(
          result is Map<String, Object?> ? result : const <String, Object?>{},
        );
      }
    } catch (_) {
      // Ignora salida no JSON (p. ej. logs del plugin) para no romper el canal.
    }
  }

  void _failAll(final Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}

class ExternalPluginException implements Exception {
  const ExternalPluginException(this.message);
  final String message;
  @override
  String toString() => message;
}
