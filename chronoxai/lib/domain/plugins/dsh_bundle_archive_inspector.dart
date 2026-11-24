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

  static void _validateCentralDirectory(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const FormatException('ZIP truncado.');
    }
    final data = ByteData.sublistView(bytes);
    int u16(int offset) => data.getUint16(offset, Endian.little);
    int u32(int offset) => data.getUint32(offset, Endian.little);

    final minimum = bytes.length - 22;
    final searchStart = (bytes.length - 65557).clamp(0, minimum);
    var endRecord = -1;
    for (var offset = minimum; offset >= searchStart; offset--) {
      if (u32(offset) == 0x06054b50) {
        endRecord = offset;
        break;
      }
    }
    if (endRecord < 0 || u16(endRecord + 4) != 0 || u16(endRecord + 6) != 0) {
      throw const FormatException('ZIP multi-disco o directorio inválido.');
    }
    final entriesOnDisk = u16(endRecord + 8);
    final entryCount = u16(endRecord + 10);
    if (entriesOnDisk != entryCount) {
      throw const FormatException('ZIP multi-disco no permitido.');
    }
    final directorySize = u32(endRecord + 12);
    final directoryOffset = u32(endRecord + 16);
    if (entryCount > maxEntries ||
        directoryOffset + directorySize > endRecord ||
        directoryOffset + directorySize > bytes.length) {
      throw const FormatException('Directorio ZIP fuera de límites.');
    }

    var offset = directoryOffset;
    var expanded = 0;
    for (var entry = 0; entry < entryCount; entry++) {
      if (offset + 46 > bytes.length || u32(offset) != 0x02014b50) {
        throw const FormatException('Entrada ZIP inválida.');
      }
      final flags = u16(offset + 8);
      final method = u16(offset + 10);
      final compressedSize = u32(offset + 20);
      final expandedSize = u32(offset + 24);
      final nameLength = u16(offset + 28);
      final extraLength = u16(offset + 30);
      final commentLength = u16(offset + 32);
      if ((flags & 1) != 0 ||
          (method != 0 && method != 8) ||
          compressedSize == 0xffffffff ||
          expandedSize == 0xffffffff) {
        throw const FormatException(
            'ZIP cifrado, ZIP64 o compresión no permitida.');
      }
      final end = offset + 46 + nameLength + extraLength + commentLength;
      if (end > directoryOffset + directorySize || end > bytes.length) {
        throw const FormatException('Entrada ZIP truncada.');
      }
      final name = utf8
          .decode(
            bytes.sublist(offset + 46, offset + 46 + nameLength),
            allowMalformed: true,
          )
          .replaceAll('\\', '/');
      if (name.startsWith('/') ||
          name.split('/').any((final part) => part == '..')) {
        throw const FormatException(
            'El bundle contiene rutas fuera del archivo.');
      }
      if (expandedSize > maxEntryBytes) {
        throw FormatException('Entrada demasiado grande: $name');
      }
      expanded += expandedSize;
      if (expanded > maxExpandedBytes) {
        throw const FormatException('El contenido expandido supera 16 MiB.');
      }
      offset = end;
    }
    if (offset != directoryOffset + directorySize) {
      throw const FormatException('Tamaño de directorio ZIP inconsistente.');
    }
  }

  static DshBundleDiagnostic inspectBytes(
    List<int> bytes, {
    required String bundleName,
  }) {
    if (bytes.isEmpty || bytes.length > maxArchiveBytes) {
      throw const FormatException('El bundle está vacío o excede 8 MiB.');
    }

    final input = Uint8List.fromList(bytes);
    _validateCentralDirectory(input);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(input, verify: true);
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
