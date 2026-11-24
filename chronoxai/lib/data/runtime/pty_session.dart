import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

/// Estado de una sesión de terminal.
enum PtyState { starting, running, exited, failed }

/// Adaptador mínimo para poder probar el ciclo de vida sin abrir un PTY real.
abstract interface class PtyProcess {
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);
  bool kill(ProcessSignal signal);
}

typedef PtyProcessFactory = PtyProcess Function({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required Map<String, String> environment,
  required int rows,
  required int columns,
});

class _FlutterPtyProcess implements PtyProcess {
  _FlutterPtyProcess(this._pty);

  final Pty _pty;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  void write(final Uint8List data) => _pty.write(data);

  @override
  void resize(final int rows, final int columns) => _pty.resize(rows, columns);

  @override
  bool kill(final ProcessSignal signal) => _pty.kill(signal);
}

PtyProcess _startFlutterPty({
  required final String executable,
  required final List<String> arguments,
  required final String workingDirectory,
  required final Map<String, String> environment,
  required final int rows,
  required final int columns,
}) {
  return _FlutterPtyProcess(
    Pty.start(
      executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      rows: rows,
      columns: columns,
      ackRead: true,
    ),
  );
}

/// Sesión real de pseudoterminal (PTY) para el proceso PRoot.
///
/// Antes se lanzaba PRoot con tuberías y se esperaba que el rootfs trajera
/// `/usr/bin/script`; eso no es un PTY del host y falla en rootfs mínimos. Ahora
/// `flutter_pty` crea el PTY en Android y lanza PRoot directamente sobre él.
class PtySession {
  PtySession({
    required this.command,
    PtyProcessFactory? processFactory,
  }) : _processFactory = processFactory ?? _startFlutterPty;

  static final Map<int, PtySession> _active = <int, PtySession>{};
  static int _nextId = 1;

  final String command;
  final PtyProcessFactory _processFactory;
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final StreamController<int> _exit = StreamController<int>.broadcast();

  PtyProcess? _process;
  StreamSubscription<Uint8List>? _outputSubscription;
  int? _id;
  PtyState _state = PtyState.starting;
  bool _closed = false;

  Stream<Uint8List> get output => _output.stream;
  Stream<int> get exit => _exit.stream;
  PtyState get state => _state;
  int? get id => _id;
  bool get isRunning => _state == PtyState.running;

  static List<Map<String, Object?>> listActive() => _active.entries
      .map((final entry) => <String, Object?>{
            'id': entry.key,
            'running': entry.value.isRunning,
            'command': entry.value.command,
          })
      .toList(growable: false);

  static Future<void> closeActive(final int id) async {
    await _active[id]?.close();
  }

  Future<bool> start({
    required String binary,
    required List<String> arguments,
    required Map<String, String> environment,
    String? workingDirectory,
    int rows = 24,
    int columns = 80,
  }) async {
    if (_state == PtyState.running) return true;
    try {
      final process = _processFactory(
        executable: binary,
        arguments: List<String>.unmodifiable(arguments),
        environment: Map<String, String>.unmodifiable(environment),
        workingDirectory: workingDirectory ?? Directory.current.path,
        rows: rows,
        columns: columns,
      );
      _process = process;
      _id = _nextId++;
      _active[_id!] = this;
      _state = PtyState.running;
      _outputSubscription = process.output.listen(
        (final data) {
          if (!_output.isClosed) _output.add(data);
        },
        onError: (final Object error, final StackTrace stack) {
          if (!_output.isClosed) _output.addError(error, stack);
        },
      );
      unawaited(process.exitCode.then(_handleExit, onError: (final Object _) {
        _handleExit(-1);
      }));
      return true;
    } on Object {
      _state = PtyState.failed;
      return false;
    }
  }

  void _handleExit(final int code) {
    if (_state == PtyState.exited || _state == PtyState.failed) return;
    _state = PtyState.exited;
    final id = _id;
    if (id != null) _active.remove(id);
    if (!_exit.isClosed) _exit.add(code);
  }

  Future<bool> write(final String data) =>
      writeBytes(Uint8List.fromList(utf8.encode(data)));

  Future<bool> writeBytes(final List<int> bytes) async {
    final process = _process;
    if (process == null || !isRunning) return false;
    try {
      process.write(Uint8List.fromList(bytes));
      return true;
    } on Object {
      return false;
    }
  }

  void resize(final int rows, final int columns) {
    if (rows <= 0 || columns <= 0) return;
    _process?.resize(rows, columns);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final process = _process;
    _process = null;
    if (process != null && _state == PtyState.running) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          // El sistema terminará el hijo al destruir el motor/app.
        }
      } on Object {
        // El PTY ya había terminado.
      }
    }
    await _outputSubscription?.cancel();
    final id = _id;
    if (id != null) _active.remove(id);
    if (_state == PtyState.running) _state = PtyState.exited;
  }
}
