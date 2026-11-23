import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../data/runtime/local_runtime.dart';
import '../../data/runtime/pty_session.dart';
import '../../domain/terminal/pty_command.dart';
import '../../domain/terminal/terminal_buffer.dart';

/// Estado observable de la terminal.
class TerminalViewState {
  TerminalViewState({
    required this.lines,
    required this.cursorRow,
    required this.cursorCol,
    required this.title,
    this.status = TerminalStatus.starting,
    this.message = '',
    this.canType = false,
  });

  /// Líneas a pintar, ya recortadas.
  final List<TerminalLine> lines;

  /// Fila y columna del cursor **dentro de [lines]** (0-based).
  final int cursorRow;
  final int cursorCol;

  /// Qué se está ejecutando, para la cabecera.
  final String title;

  final TerminalStatus status;

  /// Explicación cuando no hay terminal.
  final String message;

  /// `true` si el proceso acepta entrada.
  final bool canType;
}

/// En qué situación está la terminal.
enum TerminalStatus {
  /// Abriendo el proceso.
  starting,

  /// Lista para escribir.
  running,

  /// El shell terminó (normalmente, el usuario escribió `exit`).
  exited,

  /// No se pudo abrir, y [TerminalViewState.message] dice por qué.
  failed,
}

/// Une el runtime (proot), el proceso nativo y el emulador de pantalla.
///
/// Se separa de la pantalla a propósito: así la lógica de «qué hacer si no hay
/// rootfs», «qué pasa cuando el proceso muere» y «qué se pinta» se puede probar
/// sin un `BuildContext`.
class TerminalController extends ChangeNotifier {
  TerminalController({required this.runtime, PtySession? session})
      : _session = session {
    _buffer = TerminalBuffer(columns: _columnas);
  }

  final LocalRuntime runtime;

  PtySession? _session;
  late final TerminalBuffer _buffer;

  /// El invitado cree tener 80 columnas porque no se puede propagar el tamaño
  /// real sin `TIOCSWINSZ`. La UI envuelve lo que se salga.
  static const int _columnas = 80;

  final List<StreamSubscription<Uint8List>> _suscripcionesSalida =
      <StreamSubscription<Uint8List>>[];
  final List<StreamSubscription<int>> _suscripcionesSalidaCodigo =
      <StreamSubscription<int>>[];

  TerminalViewState _state = TerminalViewState(
    lines: const <TerminalLine>[],
    cursorRow: 0,
    cursorCol: 0,
    title: 'Terminal',
    message: 'Abriendo el contenedor…',
  );

  TerminalViewState get state => _state;

  /// `true` si merece la pena ofrecer el reintento.
  bool get canRetry => _state.status == TerminalStatus.failed ||
      _state.status == TerminalStatus.exited;

  /// Abre la sesión.
  ///
  /// Comprueba el runtime **antes** de lanzar nada: si falta el rootfs o el
  /// dispositivo no permite ejecutar, el mensaje tiene que ser el del
  /// diagnóstico (`RuntimeStatus.message`), no un `errno 2` de `Process.start`.
  Future<void> open() async {
    await _cerrarSesion();

    final status = await runtime.status();
    if (!status.isReady) {
      _publicar(
        _state = TerminalViewState(
          lines: const <TerminalLine>[],
          cursorRow: 0,
          cursorCol: 0,
          title: 'Terminal',
          status: TerminalStatus.failed,
          message: '${status.title}.\n${status.message}',
        ),
      );
      return;
    }

    // Sin `script` no hay PTY y la terminal sería un shell sin edición de
    // línea: es mejor decirlo que ofrecer algo peor que no tenerlo.
    if (!MenuScript.disponible(runtime.paths.rootfsDir)) {
      _publicar(
        _state = TerminalViewState(
          lines: const <TerminalLine>[],
          cursorRow: 0,
          cursorCol: 0,
          title: 'Terminal',
          status: TerminalStatus.failed,
          message: 'El contenedor no tiene el comando "script" '
              '(paquete bsdutils), que es lo que permite abrir un terminal '
              'interactivo. Ejecuta "apt install -y bsdutils" desde el chat.',
        ),
      );
      return;
    }

    final comando = await runtime.interactiveCommand(
      workingDirectory: LocalRuntime.guestWorkspace,
    );

    // proot arranca `sh -c "... script ..."` en lugar del shell directo: ver
    // MenuScript.envolturaInterior para el porqué.
    final argumentos = <String>[
      ...comando.args.take(comando.args.length - 2),
      ...MenuScript.envolturaInterior(),
    ];

    final session = PtySession(command: 'proot → script → bash');
    _session = session;

    _suscripcionesSalida.add(session.output.listen((final bytes) {
      _buffer.writeBytes(bytes);
      _publicarEstado();
    }));
    _suscripcionesSalidaCodigo.add(session.exit.listen((final code) {
      _publicarEstado(code: code);
    }));

    final ok = await session.start(
      binary: comando.binary,
      arguments: argumentos,
      environment: comando.env,
      workingDirectory: runtime.paths.filesDir,
    );

    if (!ok) {
      _publicar(
        _state = TerminalViewState(
          lines: _buffer.lines,
          cursorRow: _buffer.cursorRow,
          cursorCol: _buffer.cursorCol,
          title: 'Terminal',
          status: TerminalStatus.failed,
          message: 'No se pudo arrancar proot en este dispositivo.',
        ),
      );
      return;
    }

    _publicarEstado();
  }

  /// Reenvía lo que el usuario escribe, carácter a carácter.
  Future<void> type(final String text) async {
    if (text.isEmpty) return;
    await _session?.write(text);
  }

  /// Envía una tecla de control (`Ctrl+C`, flechas, tabulador).
  Future<void> sendKey(final List<int> bytes) async {
    await _session?.writeBytes(bytes);
  }

  /// Envía un comando completo y lo ejecuta (atajo de la barra superior).
  Future<void> runCommand(final String command) async {
    // El `\r` simula Intro: es lo que espera la entrada en modo terminal.
    await _session?.write('$command\r');
  }

  /// Cierra el proceso. Se llama al salir de la pantalla.
  Future<void> disposeSession() async {
    await _cerrarSesion();
  }

  Future<void> _cerrarSesion() async {
    for (final sub in _suscripcionesSalida) {
      await sub.cancel();
    }
    for (final sub in _suscripcionesSalidaCodigo) {
      await sub.cancel();
    }
    _suscripcionesSalida.clear();
    _suscripcionesSalidaCodigo.clear();
    await _session?.close();
    _session = null;
  }

  void _publicarEstado({int? code}) {
    final filas = _buffer.lines;
    _publicar(
      _state = TerminalViewState(
        lines: filas,
        // El cursor del buffer es absoluto; la UI pinta a partir de la primera
        // línea no vacía, así que hay que restarle ese desplazamiento.
        cursorRow: (filas.length - 1).clamp(0, filas.length),
        cursorCol: _buffer.cursorCol,
        title: 'Terminal',
        status: code == null ? TerminalStatus.running : TerminalStatus.exited,
        message: code == null
            ? ''
            : 'La sesión terminó (código $code). Pulsa reintentar para abrir otra.',
        canType: code == null,
      ),
    );
  }

  void _publicar(final TerminalViewState state) {
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_cerrarSesion());
    super.dispose();
  }
}
