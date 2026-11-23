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
/// * estado de SELinux, que en algunos OEM impide `execve` incluso con
///   `targetSdk 28`.
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

  /// `true` si el dispositivo usa páginas de 16 KB.
  bool get has16KPages => pageSize >= 16384;

  /// `true` si el SO va a bloquear `execve` sobre el directorio privado.
  ///
  /// Android 10 (API 29) introdujo la restricción; las apps con `targetSdk <= 28`
  /// conservan la excepción de compatibilidad `untrusted_app_27`.
  bool get appDataExecBlocked => isAndroid && sdkInt >= 29 && targetSdk >= 29;

  /// `true` si el ABI es uno para el que empaquetamos binarios.
  bool get isSupportedAbi =>
      abi == 'arm64-v8a' || abi == 'x86_64' || abi == 'aarch64';

  @override
  String toString() => 'PlatformFacts(android: $isAndroid, sdk: $sdkInt, '
      'abi: $abi, pageSize: $pageSize, targetSdk: $targetSdk, '
      'selinux: $selinuxEnforcing, nativeLib: $nativeLibraryDir)';
}

/// Puente hacia `MainActivity` para leer [PlatformFacts].
class AndroidRuntimeChannel {
  const AndroidRuntimeChannel([this._channel = _defaultChannel]);

  static const MethodChannel _defaultChannel =
      MethodChannel('app.chronoxai/platform');

  final MethodChannel _channel;

  /// Pide los datos al lado nativo. En escritorio devuelve una aproximación
  /// basada en `dart:io`, para poder probar la lógica sin teléfono.
  Future<PlatformFacts> read() async {
    final filesDir = await _resolveFilesDir();

    if (!Platform.isAndroid) {
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
      return PlatformFacts(
        isAndroid: true,
        sdkInt: (result['sdkInt'] as num?)?.toInt() ?? 0,
        abi: (result['abi'] as String?) ?? _hostAbi(),
        pageSize: (result['pageSize'] as num?)?.toInt() ?? 4096,
        nativeLibraryDir: result['nativeLibraryDir'] as String?,
        filesDir: (result['filesDir'] as String?) ?? filesDir,
        cacheDir: (result['cacheDir'] as String?) ?? Directory.systemTemp.path,
        selinuxEnforcing: (result['selinuxEnforcing'] as bool?) ?? false,
        targetSdk: (result['targetSdk'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      return _fallback(filesDir, note: 'falta el lado Kotlin del canal');
    } on PlatformException catch (e) {
      return _fallback(filesDir,
          note: 'error en el canal nativo: ${e.message}');
    }
  }

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
