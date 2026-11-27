import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Datos del dispositivo que determinan si el runtime Linux puede funcionar.
///
/// Casi todo esto se puede deducir en Dart, pero hay tres cosas que **solo** el
/// lado nativo conoce de forma fiable:
///
/// * `nativeLibraryDir`: directorio donde el sistema extrae los `.so` del APK y
///   que tiene permiso de ejecución (`apk_data_file`) incluso con `targetSdk >= 29`;
/// * `PAGE_SIZE`: en Android 15+ puede ser 16384 y romper binarios ELF alineados
///   a 4 KB;
/// * el estado de SELinux y del proceso; el runtime no usa `execve` sobre
///   binarios del rootfs, incluso con `targetSdk >= 29`.
class PlatformFacts {
  const PlatformFacts({
    required this.isAndroid,
    required this.sdkInt,
    required this.abi,
    required this.pageSize,
    required this.nativeLibraryDir,
    required this.filesDir,
    required this.cacheDir,
    required this.selinuxEnforcing,
    required this.targetSdk,
    this.selinuxDomain,
    this.canExecuteFromData,
    this.manufacturer = '',
    this.model = '',
    this.release = '',
  });

  final bool isAndroid;
  final int sdkInt;
  final String abi;
  final int pageSize;
  final String? nativeLibraryDir;
  final String filesDir;
  final String cacheDir;
  final bool selinuxEnforcing;

  /// `targetSdkVersion` con el que se compiló la app.
  final int targetSdk;

  /// Dominio SELinux real del proceso (`u:r:untrusted_app_27:s0:…`), si se pudo
  /// leer. Es lo que decide si `execve` funciona, no una suposición.
  final String? selinuxDomain;

  /// Resultado de intentar ejecutar un binario del APK. `null` si no se pudo
  /// comprobar (escritorio, canal ausente).
  final bool? canExecuteFromData;

  final String manufacturer;
  final String model;
  final String release;

  /// `true` si el dispositivo usa páginas de 16 KB.
  bool get has16KPages => pageSize >= 16384;

  /// `true` si el SO bloquea `execve` sobre el almacenamiento privado.
  ///
  /// Se prefiere el dato medido; si no está disponible se usa la regla de
  /// compatibilidad de Android 10+: la restricción aplica a targets modernos.
  /// Esto solo sirve para diagnóstico; la terminal usa el loader de PRoot.
  bool get appDataExecBlocked {
    final measured = canExecuteFromData;
    if (measured != null) return !measured;
    return isAndroid && sdkInt >= 29 && targetSdk >= 29;
  }

  /// Dominio SELinux del proceso (`untrusted_app_27`), para diagnóstico.
  ///
  /// El formato es `u:r:<dominio>:s0:<categorías>`: el segundo campo es el rol
  /// (`r`), no el dominio; confundirlos mostraba "r" en la pantalla.
  String get expectedDomain {
    final domain = selinuxDomain;
    if (domain == null) return 'desconocido';
    final parts = domain.split(':');
    return parts.length > 2 ? parts[2] : domain;
  }

  /// `true` si el ABI es uno para el que empaquetamos binarios.
  bool get isSupportedAbi =>
      abi == 'arm64-v8a' || abi == 'x86_64' || abi == 'aarch64';

  @override
  String toString() => 'PlatformFacts(android: $isAndroid, sdk: $sdkInt, '
      'abi: $abi, pageSize: $pageSize, targetSdk: $targetSdk, '
      'selinux: $selinuxEnforcing, domain: $expectedDomain, '
      'exec: $canExecuteFromData, nativeLib: $nativeLibraryDir)';
}

/// Puente hacia `MainActivity` para leer [PlatformFacts].
class AndroidRuntimeChannel {
  const AndroidRuntimeChannel([this._channel = _defaultChannel]);

  /// Permite forzar el camino de Android en los tests.
  ///
  /// Sin esto, `Platform.isAndroid` es siempre `false` bajo `flutter test` y el
  /// código que traduce la respuesta del canal nunca se ejecutaría en las
  /// pruebas: se estaría midiendo el camino de escritorio.
  static TargetPlatform? debugTargetPlatform;

  static const MethodChannel _defaultChannel =
      MethodChannel('app.chronoxai/platform');

  final MethodChannel _channel;

  /// Restaura el bit de ejecución de los binarios y scripts de un rootfs que
  /// fue extraído por Dart (que no expone chmod en dart:io).
  Future<bool> repairRootfsExecutableBits(String rootfsPath) async {
    try {
      return await _channel.invokeMethod<bool>(
            'repairRootfsExecutableBits',
            <String, Object?>{'root': rootfsPath},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Pide los datos al lado nativo. En escritorio devuelve una aproximación
  /// basada en `dart:io`, para poder probar la lógica sin teléfono.
  Future<PlatformFacts> read() async {
    final filesDir = await _resolveFilesDir();

    final isAndroid =
        debugTargetPlatform == TargetPlatform.android || Platform.isAndroid;
    if (!isAndroid) {
      return PlatformFacts(
        isAndroid: false,
        sdkInt: 0,
        abi: _hostAbi(),
        pageSize: 4096,
        nativeLibraryDir: null,
        filesDir: filesDir,
        cacheDir: Directory.systemTemp.path,
        selinuxEnforcing: false,
        targetSdk: 0,
      );
    }

    try {
      final result = await _channel.invokeMapMethod<String, Object?>('facts');
      if (result == null) {
        return _fallback(filesDir, note: 'el canal nativo devolvió nulo');
      }
      // Los valores se convierten con comprobaciones de tipo explícitas: un
      // cast a `bool?` sobre algo que no sea `bool` lanza `TypeError` en Dart,
      // no `PlatformException`, y se escaparía de los `catch` de abajo.
      return PlatformFacts(
        isAndroid: true,
        sdkInt: _asInt(result['sdkInt']) ?? 0,
        abi: _asString(result['abi']) ?? _hostAbi(),
        pageSize: _asInt(result['pageSize']) ?? 4096,
        nativeLibraryDir: _asString(result['nativeLibraryDir']),
        filesDir: _asString(result['filesDir']) ?? filesDir,
        cacheDir: _asString(result['cacheDir']) ?? Directory.systemTemp.path,
        selinuxEnforcing: _asBool(result['selinuxEnforcing']) ?? false,
        targetSdk: _asInt(result['targetSdk']) ?? 0,
        selinuxDomain: _asString(result['selinuxDomain']),
        canExecuteFromData: _asBool(result['canExecuteFromData']),
        manufacturer: _asString(result['manufacturer']) ?? '',
        model: _asString(result['model']) ?? '',
        release: _asString(result['release']) ?? '',
      );
    } on MissingPluginException {
      return _fallback(filesDir, note: 'falta el lado Kotlin del canal');
    } on PlatformException catch (e) {
      return _fallback(filesDir,
          note: 'error en el canal nativo: ${e.message}');
    } catch (e) {
      // Cualquier otra cosa (tipo inesperado, canal mal versionado) no debe
      // tumbar el arranque de la app: se degrada y se informa.
      return _fallback(filesDir, note: 'respuesta inesperada del canal: $e');
    }
  }

  static int? _asInt(final Object? value) =>
      value is num ? value.toInt() : null;

  static String? _asString(final Object? value) =>
      value is String ? value : null;

  static bool? _asBool(final Object? value) => value is bool ? value : null;

  /// Ruta del `.so` que contiene proot, dentro del directorio de librerías nativas.
  ///
  /// `proot` se empaqueta con nombre `libproot.so` porque el sistema solo extrae
  /// a `nativeLibraryDir` los ficheros que parecen bibliotecas.
  Future<String?> prootBinaryPath() async {
    final facts = await read();
    final dir = facts.nativeLibraryDir;
    if (dir == null) return null;
    return '$dir/libproot.so';
  }

  Future<PlatformFacts> _fallback(final String filesDir,
      {required final String note}) async {
    // ignore: avoid_print
    print('[ChronoxAI] PlatformFacts degradados ($note)');
    return PlatformFacts(
      isAndroid: true,
      sdkInt: 0,
      abi: _hostAbi(),
      pageSize: 4096,
      nativeLibraryDir: null,
      filesDir: filesDir,
      cacheDir: Directory.systemTemp.path,
      selinuxEnforcing: false,
      targetSdk: 0,
    );
  }

  static Future<String> _resolveFilesDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    } catch (_) {
      // En tests unitarios sin binding de Flutter el plugin no está disponible.
      return Directory.systemTemp.path;
    }
  }

  static String _hostAbi() {
    if (!Platform.isAndroid) return 'linux-${_osName()}';
    return 'arm64-v8a';
  }

  static String _osName() {
    if (Platform.isLinux) return 'x64';
    if (Platform.isMacOS) return 'arm64';
    if (Platform.isWindows) return 'x64';
    return 'unknown';
  }
}
