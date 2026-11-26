import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.label,
    required this.fileName,
    required this.bytes,
    required this.sha256,
    required this.url,
    required this.revision,
    required this.format,
    required this.runtime,
    required this.quantization,
    required this.license,
    required this.contextWindow,
  });

  final String id;
  final String label;
  final String fileName;
  final int bytes;
  final String sha256;
  final String url;
  final String revision;
  final String format;
  final String runtime;
  final String quantization;
  final String license;
  final int contextWindow;

  Map<String, Object?> toManifestEntry() => <String, Object?>{
        'id': id,
        'label': label,
        'fileName': fileName,
        'format': format,
        'runtime': runtime,
        'bytes': bytes,
        'sha256': sha256,
        'quantization': quantization,
        'license': license,
        'source': url,
        'revision': revision,
        'contextWindow': contextWindow,
      };

  static const List<LocalModelSpec> catalog = <LocalModelSpec>[
    LocalModelSpec(
      id: 'qwen35-0.8b-q4km',
      label: 'Qwen3.5 0.8B · Q4_K_M',
      fileName: 'Qwen3.5-0.8B-Q4_K_M.gguf',
      bytes: 532517120,
      sha256:
          'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf',
      revision: '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0',
      format: 'GGUF',
      runtime: 'llama.cpp@3ba1ce0e28d991800e1585b7d3533f77213939d6',
      quantization: 'Q4_K_M',
      license: 'Apache-2.0',
      contextWindow: 2048,
    ),
    LocalModelSpec(
      id: 'qwen35-2b-q4km',
      label: 'Qwen3.5 2B · Q4_K_M',
      fileName: 'Qwen3.5-2B-Q4_K_M.gguf',
      bytes: 1280835840,
      sha256:
          'aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf',
      revision: 'f6d5376be1edb4d416d56da11e5397a961aca8ae',
      format: 'GGUF',
      runtime: 'llama.cpp@3ba1ce0e28d991800e1585b7d3533f77213939d6',
      quantization: 'Q4_K_M',
      license: 'Apache-2.0',
      contextWindow: 2048,
    ),
  ];
}

class LocalModelInstallation {
  const LocalModelInstallation({required this.spec, required this.file});

  final LocalModelSpec spec;
  final File file;
}

class ModelTransferProgress {
  const ModelTransferProgress({required this.received, required this.total});

  final int received;
  final int total;

  double get fraction =>
      total <= 0 ? 0 : (received / total).clamp(0, 1).toDouble();
}

/// Private-storage catalog and verified model installer. Large GGUF files are
/// streamed to a temporary sibling and become visible only after exact size and
/// SHA-256 validation; weights are never bundled into the APK or repository.
class LocalModelStore {
  LocalModelStore({
    Future<Directory> Function()? supportDirectory,
    List<LocalModelSpec>? catalog,
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _catalog = List<LocalModelSpec>.unmodifiable(
            catalog ?? LocalModelSpec.catalog);

  final Future<Directory> Function() _supportDirectory;
  final List<LocalModelSpec> _catalog;

  // Transfer state is process-wide, not per LocalModelStore instance. Settings,
  // session bootstrap, and model validation can each create a store; without a
  // shared guard their temporary files/manifests could race one another.
  static http.Client? _activeClient;
  static bool _transferActive = false;
  static bool _cancelTransferRequested = false;

  Future<Directory> _modelsDirectory() async {
    final support = await _supportDirectory();
    final directory = Directory(p.join(support.path, 'local_models'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File?> fileForId(String id) async {
    final spec = _catalog.where((final item) => item.id == id).firstOrNull;
    if (spec == null) return null;
    for (final installation in await installedModels()) {
      if (installation.spec.id == id) {
        final actualHash = await _hashFile(installation.file);
        if (actualHash != installation.spec.sha256) {
          throw const FileSystemException(
              'El SHA-256 del modelo instalado ya no coincide.');
        }
        return installation.file;
      }
    }
    return null;
  }

  Future<List<LocalModelInstallation>> installedModels() async {
    final directory = await _modelsDirectory();
    if (!_transferActive) await _recoverInterruptedWrites(directory);
    final manifest = await _readManifest(directory);
    final installed = <LocalModelInstallation>[];
    for (final spec in _catalog) {
      final file = File(p.join(directory.path, spec.fileName));
      if (!await file.exists() || await file.length() != spec.bytes) continue;
      if (manifest[spec.id]?['sha256'] != spec.sha256) continue;
      installed.add(LocalModelInstallation(spec: spec, file: file));
    }
    return installed;
  }

  Future<LocalModelInstallation> download(
    LocalModelSpec spec, {
    void Function(ModelTransferProgress progress)? onProgress,
  }) async {
    _requireCatalogSpec(spec);
    if (_transferActive) {
      throw StateError('Ya hay una transferencia de modelo en curso.');
    }
    _transferActive = true;
    _cancelTransferRequested = false;
    try {
      return await _download(spec, onProgress: onProgress);
    } finally {
      _transferActive = false;
    }
  }

  Future<LocalModelInstallation> _download(
    LocalModelSpec spec, {
    void Function(ModelTransferProgress progress)? onProgress,
  }) async {
    final directory = await _modelsDirectory();
    final temporary = File(p.join(directory.path, '${spec.fileName}.part'));
    var received = await temporary.exists() ? await temporary.length() : 0;
    if (received > spec.bytes) {
      await temporary.delete();
      received = 0;
    } else if (received == spec.bytes) {
      if (await _hashFile(temporary) == spec.sha256) {
        if (_cancelTransferRequested) {
          await temporary.delete();
          _throwIfTransferCancelled();
        }
        await _publishVerified(
            spec, temporary, received, spec.sha256, directory);
        return LocalModelInstallation(
          spec: spec,
          file: File(p.join(directory.path, spec.fileName)),
        );
      }
      await temporary.delete();
      received = 0;
    }

    final client = http.Client();
    _activeClient = client;
    final digestResult = _DigestCollector();
    final digestInput = sha256.startChunkedConversion(digestResult);
    var digestClosed = false;
    var rangeEndExclusive = spec.bytes;
    IOSink? output;
    try {
      _throwIfTransferCancelled();
      final request = http.Request('GET', Uri.parse(spec.url));
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await client.send(request);
      _throwIfTransferCancelled();
      var append = false;
      if (response.statusCode == HttpStatus.partialContent) {
        final contentRange = response.headers['content-range'];
        final match = contentRange == null
            ? null
            : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
        final start = int.tryParse(match?.group(1) ?? '');
        final end = int.tryParse(match?.group(2) ?? '');
        final total = int.tryParse(match?.group(3) ?? '');
        if (match == null ||
            start != received ||
            total != spec.bytes ||
            end == null ||
            end < start ||
            end >= total) {
          throw const HttpException(
              'El servidor respondió un Content-Range inválido.');
        }
        append = received > 0;
        rangeEndExclusive = end + 1;
      } else if (response.statusCode == HttpStatus.ok) {
        // Some CDNs ignore Range; restart that response safely from byte zero.
        received = 0;
        rangeEndExclusive = spec.bytes;
      } else {
        throw HttpException(
            'Descarga del modelo respondió HTTP ${response.statusCode}.');
      }

      if (append) {
        await for (final chunk in temporary.openRead()) {
          digestInput.add(chunk);
        }
      }
      onProgress
          ?.call(ModelTransferProgress(received: received, total: spec.bytes));
      output =
          temporary.openWrite(mode: append ? FileMode.append : FileMode.write);
      await for (final chunk in response.stream) {
        _throwIfTransferCancelled();
        received += chunk.length;
        if (received > spec.bytes || received > rangeEndExclusive) {
          throw const FileSystemException(
              'La respuesta excede el rango/tamaño fijado.');
        }
        output.add(chunk);
        digestInput.add(chunk);
        onProgress?.call(
            ModelTransferProgress(received: received, total: spec.bytes));
      }
      _throwIfTransferCancelled();
      await output.flush();
      await output.close();
      output = null;
      digestInput.close();
      digestClosed = true;
      if (received != rangeEndExclusive) {
        throw const FileSystemException(
            'La descarga quedó incompleta; vuelve a intentarlo para continuar.');
      }
      if (received != spec.bytes) {
        throw const FileSystemException(
            'La descarga parcial se conservó; vuelve a intentarlo para continuar.');
      }
      final actualHash = digestResult.digest.toString();
      await _publishVerified(spec, temporary, received, actualHash, directory);
      onProgress
          ?.call(ModelTransferProgress(received: received, total: spec.bytes));
      return LocalModelInstallation(
        spec: spec,
        file: File(p.join(directory.path, spec.fileName)),
      );
    } catch (_) {
      await output?.close();
      if (digestClosed == false) {
        try {
          digestInput.close();
        } catch (_) {
          // Preserve the original transfer failure.
        }
      }
      if (_cancelTransferRequested && await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  /// Stops an active download or import. Partial files are discarded.
  void cancelDownload() {
    if (!_transferActive) return;
    _cancelTransferRequested = true;
    _activeClient?.close();
  }

  void _throwIfTransferCancelled() {
    if (_cancelTransferRequested) {
      throw const FileSystemException('Transferencia cancelada.');
    }
  }

  void _requireCatalogSpec(LocalModelSpec spec) {
    if (!_catalog.any((final item) =>
        item.id == spec.id &&
        item.fileName == spec.fileName &&
        item.label == spec.label &&
        item.bytes == spec.bytes &&
        item.sha256 == spec.sha256 &&
        item.url == spec.url &&
        item.revision == spec.revision &&
        item.format == spec.format &&
        item.runtime == spec.runtime &&
        item.quantization == spec.quantization &&
        item.license == spec.license &&
        item.contextWindow == spec.contextWindow)) {
      throw ArgumentError.value(spec.id, 'spec', 'Modelo fuera del catálogo.');
    }
  }

  Future<LocalModelInstallation> importFile(File source) async {
    if (_transferActive) {
      throw StateError('Ya hay una transferencia o importación en curso.');
    }
    _transferActive = true;
    _cancelTransferRequested = false;
    try {
      return await _importFile(source);
    } finally {
      _transferActive = false;
    }
  }

  Future<LocalModelInstallation> _importFile(File source) async {
    final directory = await _modelsDirectory();
    final length = await source.length();
    final spec =
        _catalog.where((final item) => item.bytes == length).firstOrNull;
    if (spec == null) {
      throw const FileSystemException(
          'El tamaño no coincide con un modelo Qwen admitido.');
    }
    final temporary =
        File(p.join(directory.path, '${spec.fileName}.importing'));
    IOSink? output = temporary.openWrite();
    final digestResult = _DigestCollector();
    final digestInput = sha256.startChunkedConversion(digestResult);
    try {
      await for (final chunk in source.openRead()) {
        _throwIfTransferCancelled();
        output.add(chunk);
        digestInput.add(chunk);
      }
      _throwIfTransferCancelled();
      await output.flush();
      await output.close();
      output = null;
      digestInput.close();
      final actualHash = digestResult.digest.toString();
      await _publishVerified(spec, temporary, length, actualHash, directory);
      return LocalModelInstallation(
        spec: spec,
        file: File(p.join(directory.path, spec.fileName)),
      );
    } catch (_) {
      await output?.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> _recoverInterruptedWrites(Directory directory) async {
    final manifest = File(p.join(directory.path, 'models.json'));
    final manifestBackup = File('${manifest.path}.backup');
    if (!await manifest.exists() && await manifestBackup.exists()) {
      await manifestBackup.rename(manifest.path);
    }

    final indexedModels = await _readManifest(directory);
    for (final spec in _catalog) {
      final destination = File(p.join(directory.path, spec.fileName));
      final backup = File('${destination.path}.backup');
      if (await backup.exists() && indexedModels[spec.id] == null) {
        await backup.delete();
      } else if (!await destination.exists() && await backup.exists()) {
        await backup.rename(destination.path);
      }
      final partialDownload = File('${destination.path}.part');
      final interruptedImport = File('${destination.path}.importing');
      final now = DateTime.now();
      if (await partialDownload.exists() &&
          now.difference(await partialDownload.lastModified()) >
              const Duration(days: 30)) {
        await partialDownload.delete();
      }
      if (await interruptedImport.exists() &&
          now.difference(await interruptedImport.lastModified()) >
              const Duration(days: 1)) {
        await interruptedImport.delete();
      }
    }
    final manifestTemporary = File('${manifest.path}.tmp');
    if (await manifestTemporary.exists()) await manifestTemporary.delete();
  }

  Future<void> remove(LocalModelSpec spec) async {
    _requireCatalogSpec(spec);
    if (_transferActive) {
      throw StateError('Espera a que termine la transferencia del modelo.');
    }
    final directory = await _modelsDirectory();
    final file = File(p.join(directory.path, spec.fileName));
    final backup = File('${file.path}.backup');
    if (await backup.exists()) await backup.delete();
    final hadFile = await file.exists();
    if (hadFile) await file.rename(backup.path);
    try {
      final manifest = await _readManifest(directory);
      manifest.remove(spec.id);
      await _writeManifest(directory, manifest);
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // Removal is committed; stale backup cleanup can be retried later.
        }
      }
    } catch (_) {
      if (hadFile && await backup.exists()) await backup.rename(file.path);
      rethrow;
    }
  }

  Future<String> _hashFile(File file) async {
    final result = _DigestCollector();
    final input = sha256.startChunkedConversion(result);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return result.digest.toString();
  }

  Future<void> _publishVerified(
    LocalModelSpec spec,
    File temporary,
    int actualBytes,
    String actualHash,
    Directory directory,
  ) async {
    if (actualBytes != spec.bytes || actualHash != spec.sha256) {
      throw const FileSystemException(
          'Tamaño o SHA-256 del GGUF no coincide con el catálogo.');
    }
    final destination = File(p.join(directory.path, spec.fileName));
    final manifest = await _readManifest(directory);

    // A valid installation is immutable: failed/repeated transfers can never
    // replace the bytes currently used by the runtime.
    if (await destination.exists() &&
        await destination.length() == spec.bytes &&
        manifest[spec.id]?['sha256'] == spec.sha256 &&
        await _hashFile(destination) == spec.sha256) {
      if (await temporary.exists()) await temporary.delete();
      return;
    }

    final backup = File('${destination.path}.backup');
    if (await backup.exists()) {
      if (await destination.exists()) {
        await backup.delete();
      } else {
        await backup.rename(destination.path);
      }
    }
    final hadDestination = await destination.exists();
    if (hadDestination) await destination.rename(backup.path);
    try {
      await temporary.rename(destination.path);
      manifest[spec.id] = spec.toManifestEntry();
      await _writeManifest(directory, manifest);
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The committed install is valid; stale backup cleanup is recoverable.
        }
      }
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      if (hadDestination && await backup.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    }
  }

  Future<Map<String, Map<String, Object?>>> _readManifest(
      Directory directory) async {
    final file = File(p.join(directory.path, 'models.json'));
    if (!await file.exists()) return <String, Map<String, Object?>>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return <String, Map<String, Object?>>{};
      }
      final schemaVersion = decoded['schemaVersion'];
      final models = decoded['models'];
      if (schemaVersion == 1 && models is Map<String, dynamic>) {
        return models.map((final id, final value) => MapEntry(
              id,
              value is Map<String, dynamic>
                  ? Map<String, Object?>.from(value)
                  : <String, Object?>{},
            ));
      }

      // Migrate the original flat `{modelId: sha256}` manifest in memory;
      // the next successful store/remove rewrites it as schema version 1.
      final legacy = <String, Map<String, Object?>>{};
      for (final entry in decoded.entries) {
        final spec = _catalog
            .where((final candidate) => candidate.id == entry.key)
            .firstOrNull;
        if (spec != null && entry.value == spec.sha256) {
          legacy[spec.id] = spec.toManifestEntry();
        }
      }
      return legacy;
    } on FormatException {
      return <String, Map<String, Object?>>{};
    }
  }

  Future<void> _writeManifest(
      Directory directory, Map<String, Map<String, Object?>> manifest) async {
    final file = File(p.join(directory.path, 'models.json'));
    final temporary = File('${file.path}.tmp');
    final document = <String, Object?>{
      'schemaVersion': 1,
      'models': manifest,
    };
    try {
      await temporary.writeAsString(jsonEncode(document), flush: true);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    final backup = File('${file.path}.backup');
    if (await backup.exists()) {
      if (await file.exists()) {
        await backup.delete();
      } else {
        await backup.rename(file.path);
      }
    }
    final hadManifest = await file.exists();
    if (hadManifest) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The manifest is committed; stale backup cleanup is recoverable.
        }
      }
    } catch (_) {
      if (hadManifest && await backup.exists()) {
        await backup.rename(file.path);
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? _value;

  Digest get digest =>
      _value ?? (throw StateError('El SHA-256 no produjo resultado.'));

  @override
  void add(Digest value) => _value = value;

  @override
  void close() {}
}
