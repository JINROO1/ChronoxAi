import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'dsh_bundle_diagnostic.dart';

/// Reads ZIP-based `.dsh.bundle` archives without extracting them or running
/// package scripts. The archive is treated as untrusted input and bounded by
/// compressed size, entry count, expanded size, and per-entry size.
class DshBundleArchiveInspector {
  const DshBundleArchiveInspector._();

  static const int maxArchiveBytes = 8 * 1024 * 1024;
  static const int maxEntries = 256;
  static const int maxExpandedBytes = 16 * 1024 * 1024;
  static const int maxEntryBytes = 2 * 1024 * 1024;

  static DshBundleDiagnostic inspectBytes(
    List<int> bytes, {
    required String bundleName,
  }) {
    if (bytes.isEmpty || bytes.length > maxArchiveBytes) {
      throw const FormatException('El bundle está vacío o excede 8 MiB.');
    }

    final Archive archive;
    try {
      archive =
          ZipDecoder().decodeBytes(Uint8List.fromList(bytes), verify: true);
    } on Object catch (error) {
      throw FormatException('No se pudo leer el ZIP del bundle: $error');
    }
    if (archive.files.length > maxEntries) {
      throw const FormatException('El bundle contiene demasiados archivos.');
    }

    var expandedBytes = 0;
    String? packageText;
    final paths = <String>[];
    final patchFiles = <String>[];
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final normalized = file.name.replaceAll('\\', '/');
      if (normalized.startsWith('/') ||
          normalized.split('/').any((final segment) => segment == '..')) {
        throw const FormatException(
            'El bundle contiene rutas fuera del archivo.');
      }
      if (file.size > maxEntryBytes) {
        throw FormatException('Entrada demasiado grande: $normalized');
      }
      expandedBytes += file.size;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('El contenido expandido supera 16 MiB.');
      }
      paths.add(normalized);
      if (normalized.toLowerCase().endsWith('cordis.patch.yml') ||
          normalized.toLowerCase().endsWith('cordis.patch.yaml')) {
        patchFiles
            .add(utf8.decode(file.content as List<int>, allowMalformed: true));
      }
      if (normalized.toLowerCase().endsWith('package.json')) {
        packageText ??=
            utf8.decode(file.content as List<int>, allowMalformed: true);
      }
    }

    final packageMetadata = <String, Object?>{};
    if (packageText != null) {
      try {
        final decoded = jsonDecode(packageText);
        if (decoded is Map) {
          packageMetadata.addAll(decoded.map(
            (final key, final value) => MapEntry(key.toString(), value),
          ));
        }
      } on FormatException {
        // Malformed metadata must not break safe diagnostics or be executed.
      }
    }
    if (patchFiles.isNotEmpty) {
      packageMetadata['cordisPatchText'] = patchFiles.join('\n');
    }
    return DshBundleDiagnostic.inspect(
      bundleName: bundleName,
      files: paths,
      metadata: packageMetadata,
    );
  }
}
