import 'package:chronoxai/platform/android_runtime_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Comprueba cómo se traduce la respuesta del lado nativo.
///
/// El canal es la frontera entre Kotlin y Dart: un tipo inesperado aquí no debe
/// tumbar el arranque de la app, porque entonces el usuario solo ve un cierre
/// sin explicación.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.chronoxai/platform');

  void respond(final Map<String, Object?> payload) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (final call) async => payload);
  }

  setUp(() {
    respond(<String, Object?>{});
    AndroidRuntimeChannel.debugTargetPlatform = TargetPlatform.android;
  });

  tearDown(() => AndroidRuntimeChannel.debugTargetPlatform = null);

  test('interpreta una respuesta completa', () async {
    respond(<String, Object?>{
      'sdkInt': 35,
      'release': '15',
      'abi': 'arm64-v8a',
      'pageSize': 16384,
      'nativeLibraryDir': '/data/app/lib/arm64',
      'filesDir': '/data/data/x/files',
      'cacheDir': '/data/data/x/cache',
      'targetSdk': 35,
      'manufacturer': 'nubia',
      'model': 'REDMAGIC 8S Pro',
      'selinuxEnforcing': true,
      'selinuxDomain': 'u:r:untrusted_app:s0:c1,c2',
      'canExecuteFromData': true,
    });

    final facts = await const AndroidRuntimeChannel().read();

    expect(facts.sdkInt, 35);
    expect(facts.pageSize, 16384);
    expect(facts.has16KPages, isTrue);
    expect(facts.selinuxDomain, 'u:r:untrusted_app:s0:c1,c2');
    expect(facts.expectedDomain, 'untrusted_app');
    expect(facts.canExecuteFromData, isTrue);
    expect(facts.appDataExecBlocked, isFalse);
    expect(facts.manufacturer, 'nubia');
    expect(facts.model, 'REDMAGIC 8S Pro');
  });

  test('el dato medido manda sobre targetSdk', () async {
    respond(<String, Object?>{
      'sdkInt': 35,
      'targetSdk': 34,
      'canExecuteFromData': true
    });
    final facts = await const AndroidRuntimeChannel().read();
    expect(facts.appDataExecBlocked, isFalse);
  });

  test('sin medición cae a la regla de API 29', () async {
    respond(<String, Object?>{'sdkInt': 35, 'targetSdk': 34});
    final facts = await const AndroidRuntimeChannel().read();
    expect(facts.appDataExecBlocked, isTrue);
  });

  test('un tipo inesperado no lanza: degrada', () async {
    // `canExecuteFromData` como texto: el nativo cambió y no debe romper nada.
    respond(<String, Object?>{
      'sdkInt': 'treinta y cinco',
      'canExecuteFromData': 'sí',
      'selinuxEnforcing': 1,
    });

    final facts = await const AndroidRuntimeChannel().read();

    expect(facts.sdkInt, 0);
    expect(facts.canExecuteFromData, isNull);
    expect(facts.selinuxEnforcing, isFalse);
  });

  test('sin datos usa 4 KB como tamaño de página', () async {
    final facts = await const AndroidRuntimeChannel().read();
    expect(facts.pageSize, 4096);
    expect(facts.has16KPages, isFalse);
  });
}
