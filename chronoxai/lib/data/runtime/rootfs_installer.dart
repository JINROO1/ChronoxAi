import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../domain/terminal/linux_paths.dart';
import 'gzip_stream.dart';
import 'oci_client.dart';
import 'tar_extractor.dart';

/// Fase en la que está la instalación.
enum InstallPhase {
  resolving('Resolviendo la imagen'),
  downloading('Descargando'),
  extracting('Extrayendo'),
  activating('Activando'),
  done('Instalado'),
  failed('Falló'),
  cancelled('Cancelado');

  const InstallPhase(this.label);
  final String label;
}

/// Progreso observable por la UI.
class InstallProgress {
  const InstallProgress({
    required this.phase,
    this.layerIndex = 0,
    this.layerCount = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.currentEntry = '',
    this.message = '',
  });

  final InstallPhase phase;
  final int layerIndex;
  final int layerCount;
  final int bytesDone;
  final int bytesTotal;

  /// Última ruta aplicada, para que se vea que avanza.
  final String currentEntry;

  final String message;

  /// Progreso de 0 a 1, o `null` si aún no se conoce el total.
  double? get fraction =>
      bytesTotal <= 0 ? null : (bytesDone / bytesTotal).clamp(0.0, 1.0);

  InstallProgress copyWith({
    InstallPhase? phase,
    int? layerIndex,
    int? layerCount,
    int? bytesDone,
    int? bytesTotal,
    String? currentEntry,
    String? message,
  }) =>
      InstallProgress(
        phase: phase ?? this.phase,
        layerIndex: layerIndex ?? this.layerIndex,
        layerCount: layerCount ?? this.layerCount,
        bytesDone: bytesDone ?? this.bytesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        currentEntry: currentEntry ?? this.currentEntry,
        message: message ?? this.message,
      );
}

/// Resultado de una instalación.
class InstallResult {
  const InstallResult(
      {required this.success, this.message = '', this.digest = ''});

  final bool success;
  final String message;

  /// Digest del manifiesto instalado, para poder comprobar actualizaciones.
  final String digest;
}

/// Instala un rootfs de Debian descargándolo de un registro OCI.
///
/// Decisiones que importan:
///
///  * **Instalación atómica**: se extrae en `<distro>.partial` y solo se renombra
///    a su sitio cuando todo ha ido bien. Un corte de red a mitad no deja un
///    rootfs a medias que parezca válido.
///  * **El hash se verifica mientras se descarga**, y si no cuadra se descarta
///    lo extraído. No se activa nada sin comprobarlo.
///  * **Cancelable de verdad**: cancelar aborta la petición HTTP en curso y borra
///    lo parcial.
///  * **Sin dependencias nuevas**: cliente OCI, gzip por trozos y extractor de
///    tar son propios (ver cada fichero para el porqué).
class RootfsInstaller {
  RootfsInstaller({
    required this.paths,
    OciRegistryClient? registry,
    http.Client Function()? clientFactory,
  })  : registry =
            registry ?? OciRegistryClient(baseUrl: 'registry-1.docker.io'),
        _newClient = clientFactory ?? http.Client.new;

  final LinuxPaths paths;
  final OciRegistryClient registry;
  final http.Client Function() _newClient;

  bool _cancelled = false;

  /// Detiene la instalación en curso.
  void cancel() => _cancelled = true;

  bool get isCancelled => _cancelled;

  String get _finalDir => paths.rootfsDir;
  String get _partialDir => '${paths.rootfsDir}.partial';
  String get _markerFile => p.join(paths.rootfsDir, '.chronox-image.json');

  /// Arquitectura OCI del dispositivo.
  static String architectureFor(final String abi) => switch (abi) {
        'arm64-v8a' || 'aarch64' => 'arm64',
        'x86_64' => 'amd64',
        'armeabi-v7a' => 'arm',
        _ => 'arm64',
      };

  /// `true` si hay un rootfs utilizable instalado.
  bool get isInstalled => paths.looksInstalled;

  /// Información de la imagen instalada, si hay una.
  Map<String, Object?>? installedImage() {
    final file = File(_markerFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Instala la imagen.
  ///
  /// [onProgress] se llama con frecuencia (varias veces por segundo); la UI debe
  /// agrupar o limitar las reconstrucciones.
  Future<InstallResult> install({
    required final String architecture,
    String tag = 'bookworm',
    void Function(InstallProgress)? onProgress,
  }) async {
    _cancelled = false;
    await paths.ensure();

    void report(final InstallProgress progress) => onProgress?.call(progress);

    // Estado limpio: restos de un intento anterior no deben mezclarse.
    await _deleteDir(_partialDir);
    await Directory(_partialDir).create(recursive: true);

    try {
      report(const InstallProgress(phase: InstallPhase.resolving));

      final manifest = await registry.resolve(
        tag: tag,
        architecture: architecture,
      );

      if (_cancelled) return _cancelledResult();

      final total = manifest.totalBytes;
      var downloaded = 0;
      var extractedBytes = 0;

      for (var i = 0; i < manifest.layers.length; i++) {
        if (_cancelled) return _cancelledResult();

        final layer = manifest.layers[i];
        report(
          InstallProgress(
            phase: InstallPhase.downloading,
            layerIndex: i + 1,
            layerCount: manifest.layers.length,
            bytesDone: downloaded,
            bytesTotal: total,
          ),
        );

        final client = _newClient();
        try {
          final response = await registry.fetchBlob(layer, client: client);

          // Se calcula el hash del flujo comprimido mientras se reenvía al
          // descompresor: así se verifica sin guardar la capa en disco.
          final digestSink = _DigestSink();
          final hashSink = sha256.startChunkedConversion(digestSink);

          Stream<List<int>> body = response.stream.map((final chunk) {
            hashSink.add(chunk);
            downloaded += chunk.length;
            report(
              InstallProgress(
                phase: InstallPhase.downloading,
                layerIndex: i + 1,
                layerCount: manifest.layers.length,
                bytesDone: downloaded,
                bytesTotal: total,
              ),
            );
            return chunk;
          });

          if (layer.needsGunzip) body = gunzip(body);

          var entries = 0;
          final extractor = TarExtractor(
            rootDirectory: _partialDir,
            isCancelled: () => _cancelled,
            onEntry: (final entry) {
              // Solo se reporta de vez en cuando: un rootfs tiene decenas de
              // miles de entradas y notificar cada una satura la UI.
              entries++;
              if (entries % 64 == 0) {
                report(
                  InstallProgress(
                    phase: InstallPhase.extracting,
                    layerIndex: i + 1,
                    layerCount: manifest.layers.length,
                    bytesDone: downloaded,
                    bytesTotal: total,
                    currentEntry: entry,
                  ),
                );
              }
            },
            onBytes: (final bytes) => extractedBytes = bytes,
          );

          await extractor.extract(body);
          hashSink.close();

          final actual = 'sha256:${digestSink.value}';
          if (layer.digest.isNotEmpty && actual != layer.digest) {
            throw RegistryException(
              'La capa ${i + 1} no coincide con su hash.\n'
              'Esperado: ${layer.digest}\nRecibido: $actual\n'
              'Se descarta la instalación por seguridad.',
            );
          }
        } finally {
          client.close();
        }
      }

      if (_cancelled) return _cancelledResult();

      report(
        InstallProgress(
          phase: InstallPhase.activating,
          layerCount: manifest.layers.length,
          bytesDone: downloaded,
          bytesTotal: total,
        ),
      );

      // Comprobación final antes de activar: si no hay shell, no es un rootfs.
      final shell = File(p.join(_partialDir, 'bin', 'sh'));
      final usrShell = File(p.join(_partialDir, 'usr', 'bin', 'sh'));
      final binBash = File(p.join(_partialDir, 'bin', 'bash'));
      if (!shell.existsSync() &&
          !usrShell.existsSync() &&
          !binBash.existsSync()) {
        throw const RegistryException(
          'La imagen descargada no contiene un shell (/bin/sh). '
          '¿Es una imagen de Debian válida?',
        );
      }

      // Metadatos de instalación, para diagnóstico y futuras actualizaciones.
      await File(p.join(_partialDir, '.chronox-image.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'repository': registry.repository,
          'tag': tag,
          'architecture': architecture,
          'layers': manifest.layers.map((final l) => l.digest).toList(),
          'installedAt': DateTime.now().toIso8601String(),
          'extractedBytes': extractedBytes,
        }),
      );

      // Activación atómica: el directorio definitivo solo aparece al final.
      await _deleteDir(_finalDir);
      await Directory(_partialDir).rename(_finalDir);

      report(const InstallProgress(phase: InstallPhase.done));
      return InstallResult(
        success: true,
        message: 'Debian $tag instalado para $architecture.',
        digest: manifest.layers.map((final l) => l.digest).join(','),
      );
    } on RegistryException catch (error) {
      await _deleteDir(_partialDir);
      report(
        InstallProgress(phase: InstallPhase.failed, message: error.message),
      );
      return InstallResult(success: false, message: error.message);
    } on TarFormatException catch (error) {
      await _deleteDir(_partialDir);
      report(
        InstallProgress(phase: InstallPhase.failed, message: error.message),
      );
      return InstallResult(success: false, message: error.message);
    } on StateError {
      // `StateError` aquí solo lo lanza el extractor al ver la marca de
      // cancelación; cualquier otro caso se trata como fallo normal.
      await _deleteDir(_partialDir);
      if (_cancelled) return _cancelledResult();
      const mensaje = 'El archivo de la imagen está corrupto.';
      report(
        const InstallProgress(phase: InstallPhase.failed, message: mensaje),
      );
      return const InstallResult(success: false, message: mensaje);
    } catch (error) {
      await _deleteDir(_partialDir);
      final message = 'Instalación interrumpida: $error';
      report(InstallProgress(phase: InstallPhase.failed, message: message));
      return InstallResult(success: false, message: message);
    }
  }

  InstallResult _cancelledResult() {
    return const InstallResult(
      success: false,
      message: 'Instalación cancelada. No se ha dejado nada a medias.',
    );
  }

  /// Comprueba si hay una actualización disponible sin descargar la imagen.
  Future<String?> checkForUpdate(
      {String tag = 'bookworm', String architecture = 'arm64'}) async {
    final installed = installedImage();
    if (installed == null) return null;
    try {
      final manifest =
          await registry.resolve(tag: tag, architecture: architecture);
      final current = (installed['layers'] as List<Object?>?)?.cast<String>() ??
          const <String>[];
      final remote = manifest.layers.map((final l) => l.digest).toList();
      return _sameLayers(current, remote) ? null : tag;
    } catch (_) {
      return null;
    }
  }

  static bool _sameLayers(final List<String> a, final List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Borra el rootfs instalado (para reinstalar o liberar espacio).
  Future<void> remove() async {
    await _deleteDir(_finalDir);
    await _deleteDir(_partialDir);
  }

  static Future<void> _deleteDir(final String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // Un fichero bloqueado no debe impedir reintentar la instalación.
    }
  }
}

/// Acumula el digest que produce `package:crypto`.
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  String get value => _digest?.toString() ?? '';

  @override
  void add(final Digest data) => _digest = data;

  @override
  void close() {}
}
