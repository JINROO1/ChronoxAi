import 'package:chronoxai/platform/android_permissions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Sin binding, `MethodChannel` no tiene mensajero y lanza una excepción
  // distinta a la que capturan los métodos: el test pasaría a comprobar otra
  // cosa. Con el binding inicializado, el camino es el real (MissingPluginException).
  TestWidgetsFlutterBinding.ensureInitialized();

  // En el entorno de test no hay canal nativo ni Android: todo debe degradar
  // sin lanzar. Es justo el escenario que provoca cuelgues cuando se usa
  // `await` sobre un MethodChannel que nunca responde.
  group('AndroidPermissions — degradación sin canal', () {
    const permissions = AndroidPermissions();

    setUp(() {
      // Sin este simulacro, `invokeMethod` propaga un `AssertionError` sobre el
      // binding en lugar de un `MissingPluginException`, y se estaría probando
      // un camino que no existe en la app real.
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app.chronoxai/permissions'),
            // Map vacío: desde Dart 3, `invokeMethod<bool>` lanza TypeError si el
            // canal responde `null`. Es lo que devuelve una implementación real
            // que no conoce el método, así que se simula ese caso.
            (final call) async => <String, Object?>{},
          );
    });

    test('requestNotifications no concede sin canal', () async {
      expect(await permissions.requestNotifications(), isFalse);
    });

    test('isBatteryUnrestricted devuelve false sin canal', () async {
      expect(await permissions.isBatteryUnrestricted(), isFalse);
    });

    test('requestBatteryUnrestricted no lanza', () async {
      await expectLater(permissions.requestBatteryUnrestricted(), completes);
    });

    test('startTerminalService informa de false sin canal', () async {
      expect(await permissions.startTerminalService(), isFalse);
    });

    test('stopTerminalService no lanza', () async {
      await expectLater(permissions.stopTerminalService(), completes);
    });
  });
}
