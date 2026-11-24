import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Estado de una sesión de terminal.
enum PtyState { starting, running, exited, failed }

/// Sesión de terminal conectada a un proceso del dispositivo.
///
/// El proceso lo posee el lado nativo ([PtySession.kt]) por una razón concreta:
/// aquí se necesita *escribir* en su entrada y matarlo con todos sus
/// descendientes, y eso solo se puede hacer con el `Process` de Kotlin, no con
/// un descriptor que se haya soltado.
///
/// Esta clase no interpreta los bytes: los reenvía a quien escuche. Convertir a
/// texto aquí rompería las secuencias de escape que caen partidas entre trozos.
class PtySession {
  PtySession({
    required this.command,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('app.chronoxai/pty');

  /// Lo que se va a ejecutar, para mostrarlo en el diagnóstico.
  final String command;

  final MethodChannel _channel;

  // MethodChannel tiene un único callback por canal. Varias terminales no deben
  // sobrescribirse el handler mutuamente: enruta los eventos nativos por el id
  // del PTY a su sesión Dart correspondiente.
  static final Map<int, PtySession> _sessionsById = <int, PtySession>{};

  static Future<void> _dispatchNative(MethodCall call) async {
    final args = call.arguments;
    final id = args is Map ? args['id'] : null;
    if (id is int) await _sessionsById[id]?._handleNative(call);
  }

  static Future<List<Map<String, Object?>>> listActive({
    final MethodChannel? channel,
  }) async {
    final rows = await (channel ?? const MethodChannel('app.chronoxai/pty'))
        .invokeListMethod<Object?>('list');
    return (rows ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map((final row) => row.cast<String, Object?>())
        .toList(growable: false);
  }

  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final StreamController<int> _exit = StreamController<int>.broadcast();

  int? _id;
  PtyState _state = PtyState.starting;

  /// Bytes que produce el proceso.
  Stream<Uint8List> get output => _output.stream;

  /// Código de salida, cuando el proceso termina.
  Stream<int> get exit => _exit.stream;

  PtyState get state => _state;
  int? get id => _id;
  bool get isRunning => _state == PtyState.running;

  /// Arranca el proceso.
  ///
  /// [binary] y [arguments] son lo que devuelve `ProotCommandBuilder`; aquí no
  /// se construye nada para no duplicar el orden canónico de proot.
  Future<bool> start({
    required String binary,
    required List<String> arguments,
    required Map<String, String> environment,
    String? workingDirectory,
  }) async {
    if (_state == PtyState.running) return true;

    _channel.setMethodCallHandler(_dispatchNative);

    try {
      final id = await _channel.invokeMethod<int>('start', <String, Object?>{
        'binary': binary,
        'args': arguments,
        'env': environment,
        'cwd': workingDirectory,
      });
      if (id == null) {
        _state = PtyState.failed;
        return false;
      }
      _id = id;
      _sessionsById[id] = this;
      _state = PtyState.running;
      return true;
    } on PlatformException {
      _state = PtyState.failed;
      return false;
    } on MissingPluginException {
      // Ocurre en `flutter test` y en escritorio, donde no hay lado nativo.
      _state = PtyState.failed;
      return false;
    }
  }

  Future<void> _handleNative(final MethodCall call) async {
    switch (call.method) {
      case 'output':
        final args = call.arguments;
        if (args is Map) {
          final data = args['data'];
          if (data is Uint8List) {
            if (!_output.isClosed) _output.add(data);
          } else if (data is List<int>) {
            if (!_output.isClosed) _output.add(Uint8List.fromList(data));
          }
        }
      case 'exit':
        final args = call.arguments;
        final code = (args is Map ? args['exitCode'] : null) as int? ?? -1;
        _state = PtyState.exited;
        if (!_exit.isClosed) _exit.add(code);
      default:
        break;
    }
  }

  /// Escribe en la entrada del proceso.
  ///
  /// Devuelve `false` si el proceso ya no acepta datos, para que la UI pueda
  /// desactivar la entrada en vez de tragarse lo que el usuario teclea.
  Future<bool> write(final String data) async {
    final id = _id;
    if (id == null || _state != PtyState.running) return false;
    try {
      final result =
          await _channel.invokeMethod<bool>('write', <String, Object?>{
        'id': id,
        'data': Uint8List.fromList(utf8.encode(data)),
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Escribe bytes crudos (para teclas de control como `Ctrl+C`).
  Future<bool> writeBytes(final List<int> bytes) async {
    final id = _id;
    if (id == null || _state != PtyState.running) return false;
    try {
      final result =
          await _channel.invokeMethod<bool>('write', <String, Object?>{
        'id': id,
        'data': Uint8List.fromList(bytes),
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Cierra la sesión y el proceso con sus descendientes.
  Future<void> close() async {
    final id = _id;
    _id = null;
    if (id != null) _sessionsById.remove(id);
    _state = PtyState.exited;
    if (id != null) {
      try {
        await _channel.invokeMethod<void>('close', <String, Object?>{'id': id});
      } on PlatformException {
        // El proceso ya no existía: no hay nada que cerrar.
      } on MissingPluginException {
        // Sin lado nativo no hay nada que cerrar.
      }
    }
    await _output.close();
    await _exit.close();
  }
}

/// Secuencias de control que la UI necesita enviar.
///
/// Se nombran por lo que hacen, no por su byte, porque el byte cambia según el
/// modo del terminal (por ejemplo, `Ctrl+C` en modo literal es 0x03, que es lo
/// que se envía siempre aquí).
abstract final class ControlKeys {
  static const int ctrlC = 0x03;
  static const int ctrlD = 0x04;
  static const int ctrlZ = 0x1A;
  static const int ctrlL = 0x0C;
  static const int escape = 0x1B;
  static const int tab = 0x09;

  /// Flecha arriba en modo ANSI (`ESC [ A`): recorre el historial del shell.
  static const List<int> arrowUp = <int>[0x1B, 0x5B, 0x41];
  static const List<int> arrowDown = <int>[0x1B, 0x5B, 0x42];
  static const List<int> arrowRight = <int>[0x1B, 0x5B, 0x43];
  static const List<int> arrowLeft = <int>[0x1B, 0x5B, 0x44];
}
