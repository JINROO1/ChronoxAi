import 'package:chronoxai/domain/terminal/runtime_compat.dart';
import 'package:chronoxai/platform/android_runtime_channel.dart';
import 'package:flutter_test/flutter_test.dart';

PlatformFacts facts({
  int sdkInt = 35,
  String abi = 'arm64-v8a',
  int pageSize = 4096,
  int targetSdk = 28,
  bool? canExecuteFromData = true,
  String? selinuxDomain = 'u:r:untrusted_app_27:s0:c1,c2',
  String manufacturer = 'Google',
  String model = 'Pixel',
  bool isAndroid = true,
}) => PlatformFacts(
  isAndroid: isAndroid,
  sdkInt: sdkInt,
  abi: abi,
  pageSize: pageSize,
  nativeLibraryDir: '/data/app/lib/arm64',
  filesDir: '/data/data/app.chronoxai/files',
  cacheDir: '/data/data/app.chronoxai/cache',
  selinuxEnforcing: true,
  targetSdk: targetSdk,
  selinuxDomain: selinuxDomain,
  canExecuteFromData: canExecuteFromData,
  manufacturer: manufacturer,
  model: model,
  release: '15',
);

void main() {
  group('RuntimeCompatibility — permiso de ejecución', () {
    test('Android 15 con targetSdk 28 y dominio _27 está soportado', () {
      final issues = RuntimeCompatibility.evaluate(facts());
      expect(issues.where((final i) => i.isBlocking), isEmpty);
      expect(RuntimeCompatibility.canRun(facts()), isTrue);
    });

    test('el dato medido manda sobre la regla teórica', () {
      // targetSdk alto (en teoría bloqueado) pero el dispositivo permite exec:
      // una ROM que incumple la regla no debe bloquear la app.
      final measured = facts(targetSdk: 34, canExecuteFromData: true);
      expect(RuntimeCompatibility.canRun(measured), isTrue);
    });

    test('bloquea si el dominio real no permite ejecutar', () {
      final blocked = facts(canExecuteFromData: false);
      final issues = RuntimeCompatibility.evaluate(blocked);

      final issue = issues.singleWhere((final i) => i.isBlocking);
      expect(issue.title, contains('bloquea ejecutar'));
      expect(issue.detail, contains('untrusted_app_27'));
      expect(issue.advice, contains('Desinstala'));
      expect(RuntimeCompatibility.canRun(blocked), isFalse);
    });

    test('sin dato medido se aplica la regla de API 29', () {
      final unknown = facts(targetSdk: 34, canExecuteFromData: null);
      expect(RuntimeCompatibility.canRun(unknown), isFalse);

      final exempt = facts(targetSdk: 28, canExecuteFromData: null);
      expect(RuntimeCompatibility.canRun(exempt), isTrue);
    });
  });

  group('RuntimeCompatibility — arquitectura y versión', () {
    test('rechaza ARM de 32 bits', () {
      final issues = RuntimeCompatibility.evaluate(
        facts(abi: 'armeabi-v7a'),
      );
      final issue = issues.singleWhere((final i) => i.isBlocking);
      expect(issue.title, contains('Procesador'));
      expect(issue.detail, contains('armeabi-v7a'));
    });

    test('acepta x86_64 (emulador)', () {
      expect(RuntimeCompatibility.canRun(facts(abi: 'x86_64')), isTrue);
    });

    test('rechaza Android anterior a 7.0', () {
      final issues = RuntimeCompatibility.evaluate(facts(sdkInt: 23));
      expect(
        issues.any((final i) => i.isBlocking && i.title.contains('antiguo')),
        isTrue,
      );
    });

    test('nombra la versión de Android en el diagnóstico', () {
      final with15 = RuntimeCompatibility.evaluate(facts(sdkInt: 35));
      final with13 = RuntimeCompatibility.evaluate(facts(sdkInt: 33));
      // El aviso de "app antigua" solo aparece en Android 15+.
      expect(
        with15.any((final i) => i.title.contains('versión anterior')),
        isTrue,
      );
      expect(
        with13.any((final i) => i.title.contains('versión anterior')),
        isFalse,
      );
    });
  });

  group('RuntimeCompatibility — páginas de 16 KB', () {
    test('bloquea si el dispositivo usa 16 KB y los binarios son de 4 KB', () {
      final issues = RuntimeCompatibility.evaluate(
        facts(pageSize: 16384),
        binariesAligned16K: false,
      );
      final issue = issues.singleWhere((final i) => i.isBlocking);
      expect(issue.title, contains('16 KB'));
      expect(issue.advice, contains('max-page-size=16384'));
    });

    test('con binarios alineados no hay bloqueo', () {
      final ok = facts(pageSize: 16384);
      expect(
        RuntimeCompatibility.canRun(ok, binariesAligned16K: true),
        isTrue,
      );
    });

    test('sin verificar, avisa pero no bloquea', () {
      final issues = RuntimeCompatibility.evaluate(
        facts(pageSize: 16384),
        binariesAligned16K: null,
      );
      expect(issues.where((final i) => i.isBlocking), isEmpty);
      expect(
        issues.any((final i) => i.severity == CompatSeverity.warning),
        isTrue,
      );
    });

    test('con páginas de 4 KB no dice nada', () {
      final issues = RuntimeCompatibility.evaluate(facts());
      expect(issues.any((final i) => i.title.contains('16 KB')), isFalse);
    });
  });

  group('RuntimeCompatibility — fabricantes', () {
    test('avisa de RedMagic OS en dispositivos Nubia/ZTE', () {
      final issues = RuntimeCompatibility.evaluate(
        facts(manufacturer: 'nubia'),
      );
      final issue = issues.singleWhere((final i) => i.title.contains('segundo'));
      expect(issue.severity, CompatSeverity.warning);
      expect(issue.detail, contains('RedMagic OS'));
      expect(issue.advice, contains('batería'));
      // Es un aviso, no un bloqueo: la app funciona igual.
      expect(RuntimeCompatibility.canRun(facts(manufacturer: 'nubia')), isTrue);
    });

    test('también reconoce Xiaomi, OPPO y Samsung', () {
      for (final vendor in <String>['Xiaomi', 'OPPO', 'samsung', 'OnePlus']) {
        final issues = RuntimeCompatibility.evaluate(facts(manufacturer: vendor));
        expect(
          issues.any((final i) => i.title.contains('segundo')),
          isTrue,
          reason: 'no avisó para $vendor',
        );
      }
    });

    test('un fabricante desconocido no genera avisos falsos', () {
      final issues = RuntimeCompatibility.evaluate(
        facts(manufacturer: 'Fairphone'),
      );
      expect(issues.any((final i) => i.title.contains('segundo')), isFalse);
    });

    test('ordena los bloqueantes antes que los avisos', () {
      final issues = RuntimeCompatibility.evaluate(
        facts(manufacturer: 'nubia', pageSize: 16384),
        binariesAligned16K: false,
      );
      expect(issues.first.severity, CompatSeverity.blocking);
    });
  });

  group('RuntimeCompatibility — resumen', () {
    test('resume el dispositivo en una línea', () {
      final line = RuntimeCompatibility.summary(
        facts(sdkInt: 35, pageSize: 16384),
      );
      expect(line, contains('Android 15'));
      expect(line, contains('arm64-v8a'));
      expect(line, contains('16 KB'));
      expect(line, contains('exec OK'));
    });

    test('marca exec bloqueado cuando no se puede ejecutar', () {
      final line = RuntimeCompatibility.summary(
        facts(canExecuteFromData: false),
      );
      expect(line, contains('exec bloqueado'));
    });
  });
}
