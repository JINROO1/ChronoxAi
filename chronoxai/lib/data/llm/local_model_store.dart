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
  });

  final String id;
  final String label;
  final String fileName;
  final int bytes;
  final String sha256;
  final String url;
  final String revision;

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
  LocalModelStore({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  http.Client? _activeClient;

  Future<Directory> _modelsDirectory() async {
    final support = await _supportDirectory();
    final directory = Directory(p.join(support.path, 'local_models'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File?> fileForId(String id) async {
    final spec =
        LocalModelSpec.catalog.where((final item) => item.id == id).firstOrNull;
    if (spec == null) return null;
    for (final installation in await installedModels()) {
      if (installation.spec.id == id) return installation.file;
    }
    return null;
  }

  Future<List<LocalModelInstallation>> installedModels() async {
    final directory = await _modelsDirectory();
    final manifest = await _readManifest(directory);
    final installed = <LocalModelInstallation>[];
    for (final spec in LocalModelSpec.catalog) {
      final file = File(p.join(directory.path, spec.fileName));
      if (!await file.exists() || await file.length() != spec.bytes) continue;
      if (manifest[spec.id] != spec.sha256) continue;
      installed.add(LocalModelInstallation(spec: spec, file: file));
    }
    return installed;
  }

  Future<LocalModelInstallation> download(
    LocalModelSpec spec, {
    void Function(ModelTransferProgress progress)? onProgress,
  }) async {
    final directory = await _modelsDirectory();
    final temporary = File(p.join(directory.path, '${spec.fileName}.part'));
    final client = http.Client();
    _activeClient = client;
    final digestResult = _DigestCollector();
    final digestInput = sha256.startChunkedConversion(digestResult);
    var received = 0;
    IOSink? output;
    try {
      final request = http.Request('GET', Uri.parse(spec.url));
      final response = await client.send(request);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
            'Descarga del modelo respondió HTTP ${response.statusCode}.');
      }
      output = temporary.openWrite();
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > spec.bytes) {
          throw const FileSystemException('El modelo supera el tamaño fijado.');
        }
        output.add(chunk);
        digestInput.add(chunk);
        onProgress?.call(
            ModelTransferProgress(received: received, total: spec.bytes));
      }
      await output.flush();
      await output.close();
      output = null;
      digestInput.close();
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
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  /// Stops an active HTTP transfer. The incomplete `.part` file is discarded.
  void cancelDownload() => _activeClient?.close();

  Future<LocalModelInstallation> importFile(File source) async {
    final directory = await _modelsDirectory();
    final length = await source.length();
    final spec = LocalModelSpec.catalog
        .where((final item) => item.bytes == length)
        .firstOrNull;
    if (spec == null) {
      throw const FileSystemException(
          'El tamaño no coincide con un modelo Qwen admitido.');
    }
    final temporary =
        File(p.join(directory.path, '${spec.fileName}.importing'));
    final output = temporary.openWrite();
    final digestResult = _DigestCollector();
    final digestInput = sha256.startChunkedConversion(digestResult);
    try {
      await for (final chunk in source.openRead()) {
        output.add(chunk);
        digestInput.add(chunk);
      }
      await output.flush();
      await output.close();
      digestInput.close();
      final actualHash = digestResult.digest.toString();
      await _publishVerified(spec, temporary, length, actualHash, directory);
      return LocalModelInstallation(
        spec: spec,
        file: File(p.join(directory.path, spec.fileName)),
      );
    } catch (_) {
      await output.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> remove(LocalModelSpec spec) async {
    final directory = await _modelsDirectory();
    final file = File(p.join(directory.path, spec.fileName));
    if (await file.exists()) await file.delete();
    final manifest = await _readManifest(directory);
    manifest.remove(spec.id);
    await _writeManifest(directory, manifest);
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
    await temporary.rename(destination.path);
    final manifest = await _readManifest(directory);
    manifest[spec.id] = spec.sha256;
    await _writeManifest(directory, manifest);
  }

  Future<Map<String, String>> _readManifest(Directory directory) async {
    final file = File(p.join(directory.path, 'models.json'));
    if (!await file.exists()) return <String, String>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return <String, String>{};
      return decoded.map((final key, final value) =>
          MapEntry<String, String>(key, value.toString()));
    } on FormatException {
      return <String, String>{};
    }
  }

  Future<void> _writeManifest(
      Directory directory, Map<String, String> manifest) async {
    final file = File(p.join(directory.path, 'models.json'));
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(manifest), flush: true);
    await temporary.rename(file.path);
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
