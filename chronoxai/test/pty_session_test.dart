import 'dart:typed_data';

import 'package:chronoxai/data/runtime/pty_session.dart';
import 'package:chronoxai/domain/terminal/pty_command.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simula el lado nativo del canal `app.chronoxai/pty`.
///
/// Se sustituye el `MethodChannel`, no la lógica de Dart: así se comprueba el
/// contrato entre ambos lados (nombres de método, forma de los argumentos y de
/// los eventos) que es justo lo que no se puede probar en un dispositivo desde
/// CI.
class CanalFalso {
  CanalFalso();

  final List<MethodCall> llamadas = <MethodCall>[];

  int _siguienteId = 1;

  Future<Object?> Function(MethodCall)? respuesta;

  MethodChannel instalar(final String nombre) {
    final canal = MethodChannel(nombre);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canal, (final call) async {
      llamadas.add(call);
      if (respuesta != null) return respuesta!(call);
      return switch (call.method) {
        'start' => _siguienteId++,
        'write' => true,
        'close' => null,
        _ => null,
      };
    });
    return canal;
  }

  /// Envía un evento del lado nativo hacia Dart.
  Future<void> emitir(final String metodo, final Map<String, Object?> args) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'app.chronoxai/pty',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(metodo, args),
      ),
      (_) {},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PtySession', () {
    late CanalFalso canal;

    setUp(() {
      canal = CanalFalso();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('app.chronoxai/pty'),
        null,
      );
    });

    test('start envía binario, argumentos, entorno y directorio', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      final sesion = PtySession(command: 'proot', channel: canalReal);

      final ok = await sesion.start(
        binary: '/data/app/lib/libproot.so',
        arguments: <String>['--kill-on-exit', '--rootfs=/rootfs'],
        environment: <String, String>{'LD_LIBRARY_PATH': '/data/app/lib'},
        workingDirectory: '/data/data/app.chronoxai/files',
      );

      expect(ok, isTrue);
      expect(sesion.isRunning, isTrue);
      expect(sesion.id, isNotNull);

      final llamada = canal.llamadas.single;
      expect(llamada.method, 'start');
      final args = llamada.arguments as Map<Object?, Object?>;
      expect(args['binary'], '/data/app/lib/libproot.so');
      expect(args['args'], contains('--rootfs=/rootfs'));
      expect(
        (args['env']! as Map<Object?, Object?>)['LD_LIBRARY_PATH'],
        '/data/app/lib',
      );
      expect(args['cwd'], '/data/data/app.chronoxai/files');
    });

    test('la salida nativa llega a la pantalla en orden', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      final sesion = PtySession(command: 'proot', channel: canalReal);
      await sesion.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      final recibido = <String>[];
      sesion.output.listen((final bytes) => recibido.add(String.fromCharCodes(bytes)));

      await canal.emitir('output', <String, Object?>{
        'id': 1,
        'data': Uint8List.fromList(<int>[104, 111, 108, 97]),
      });
      await canal.emitir('output', <String, Object?>{
        'id': 1,
        'data': Uint8List.fromList(<int>[10]),
      });
      // Los eventos llegan por el bucle de mensajes.
      await Future<void>.delayed(Duration.zero);

      expect(recibido.join(), 'hola\n');
    });

    test('el código de salida se publica y cierra la sesión', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      final sesion = PtySession(command: 'proot', channel: canalReal);
      await sesion.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      final codigos = <int>[];
      sesion.exit.listen(codigos.add);

      await canal.emitir('exit', <String, Object?>{'id': 1, 'exitCode': 0});
      await Future<void>.delayed(Duration.zero);

      expect(codigos, <int>[0]);
      expect(sesion.state, PtyState.exited);
      expect(sesion.isRunning, isFalse);
    });

    test('write envía los bytes al proceso', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      final sesion = PtySession(command: 'proot', channel: canalReal);
      await sesion.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      final ok = await sesion.write('ls\r');

      expect(ok, isTrue);
      final escritura = canal.llamadas.firstWhere((final c) => c.method == 'write');
      final args = escritura.arguments as Map<Object?, Object?>;
      expect((args['data']! as Uint8List).toList(), 'ls\r'.codeUnits);
    });

    test('Ctrl+C se envía como byte de control, no como texto', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      final sesion = PtySession(command: 'proot', channel: canalReal);
      await sesion.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      await sesion.writeBytes(const <int>[ControlKeys.ctrlC]);

      final escritura = canal.llamadas.firstWhere((final c) => c.method == 'write');
      final args = escritura.arguments as Map<Object?, Object?>;
      expect((args['data']! as Uint8List).toList(), <int>[3]);
    });

    test('tras close() ya no se acepta escritura', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      final sesion = PtySession(command: 'proot', channel: canalReal);
      await sesion.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      await sesion.close();

      expect(await sesion.write('x'), isFalse);
      expect(
        canal.llamadas.where((final c) => c.method == 'close').length,
        1,
      );
    });

    test('sin lado nativo la sesión falla en vez de quedarse colgada', () async {
      // Canal sin manejador: es lo que ocurre en `flutter test`.
      final sesion = PtySession(command: 'proot', channel: const MethodChannel('app.chronoxai/pty'));

      final ok = await sesion.start(
        binary: '/bin/sh',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      expect(ok, isFalse);
      expect(sesion.state, PtyState.failed);
    });

    test('si el nativo devuelve un error, start no lanza', () async {
      final canalReal = canal.instalar('app.chronoxai/pty');
      canal.respuesta = (final _) async =>
          throw PlatformException(code: 'sin_binario', message: 'no');

      final sesion = PtySession(command: 'proot', channel: canalReal);
      final ok = await sesion.start(
        binary: '',
        arguments: const <String>[],
        environment: const <String, String>{},
      );

      expect(ok, isFalse);
      expect(sesion.state, PtyState.failed);
    });
  });

  group('MenuScript', () {
    test('script recibe -q, -f y -e', () {
      final args = MenuScript.argumentos();
      expect(args.first, 'script');
      expect(args, containsAll(<String>['-q', '-f', '-e']));
    });

    test('el comando interior fija TERM y hace exec del shell', () {
      expect(MenuScript.comandoInterior(), contains('TERM=xterm-256color'));
      expect(MenuScript.comandoInterior(), contains('exec /bin/bash -l'));
    });

    test('la envoltura pasa por sh -c y no deja procesos intermedios', () {
      final args = MenuScript.envolturaInterior();
      expect(args.first, '/bin/sh');
      expect(args[1], '-c');
      expect(args[2], contains('exec script'));
      expect(args[2], contains('exec /bin/bash -l'));
    });

    test('en un sistema real, script existe si el rootfs lo tiene', () {
      // Sin rootfs no hay nada que comprobar: el contrato es "false, no error".
      expect(MenuScript.disponible('/ruta/que/no/existe'), isFalse);
    });
  });
}
