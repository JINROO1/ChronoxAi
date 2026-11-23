import 'dart:io';
import 'dart:typed_data';

/// Máquina `e_machine` de ELF para AArch64.
const int emAarch64 = 0xB7;

/// Máquina `e_machine` de ELF para x86-64.
const int emX8664 = 0x3E;

/// Tamaño de página de 16 KB, que es el mínimo exigido por Android 15+.
const int pageSize16K = 16384;

/// Resultado de inspeccionar un binario ELF.
///
/// Existe porque Android 15+ puede arrancar dispositivos con páginas de 16 KB y
/// cualquier binario con segmentos `LOAD` alineados a 4 KB falla en tiempo de
/// carga con `SIGBUS` o `ELF load failed`. Sin esta comprobación el usuario ve un
/// error opaco de `proot` en lugar de un diagnóstico.
class ElfInfo {
  const ElfInfo({
    required this.is64Bit,
    required this.isLittleEndian,
    required this.machine,
    required this.interpreter,
    required this.loadAlignments,
  });

  final bool is64Bit;
  final bool isLittleEndian;
  final int machine;

  /// Valor de `PT_INTERP` (el loader dinámico), o `null` si es estático.
  final String? interpreter;

  /// Alineación (`p_align`) de cada segmento `PT_LOAD`, en orden.
  final List<int> loadAlignments;

  /// `true` si todos los segmentos `LOAD` están alineados a 16 KB o más.
  ///
  /// Un binario alineado a 16 KB funciona tanto en dispositivos de 4 KB como de
  /// 16 KB, porque 16384 es múltiplo de 4096.
  bool get supports16KPages =>
      loadAlignments.isNotEmpty &&
      loadAlignments.every((final align) => align >= pageSize16K);

  /// Alineación mínima encontrada; 0 si no hay segmentos `LOAD`.
  int get minLoadAlignment => loadAlignments.isEmpty
      ? 0
      : loadAlignments.reduce((final a, final b) => a < b ? a : b);

  String get machineName => switch (machine) {
    emAarch64 => 'arm64-v8a (AArch64)',
    emX8664 => 'x86_64',
    0x28 => 'armeabi-v7a (ARM)',
    0x03 => 'x86',
    _ => 'desconocida (0x${machine.toRadixString(16)})',
  };

  bool get isAndroidCompatible => machine == emAarch64 || machine == emX8664;

  @override
  String toString() =>
      'ElfInfo(machine: $machineName, interp: ${interpreter ?? 'estático'}, '
      'minAlign: $minLoadAlignment, 16K: $supports16KPages)';
}

/// Error de formato ELF con contexto suficiente para diagnosticar.
class ElfFormatException implements Exception {
  const ElfFormatException(this.message);
  final String message;
  @override
  String toString() => 'ElfFormatException: $message';
}

/// Parser ELF mínimo, sin dependencias, para validar binarios antes de ejecutarlos.
abstract final class ElfInspector {
  static const int _ptLoad = 1;
  static const int _ptInterp = 3;

  /// Inspecciona el fichero en [path].
  static Future<ElfInfo> inspectFile(final String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ElfFormatException('No existe el fichero: $path');
    }
    final bytes = await file.readAsBytes();
    return inspect(bytes, source: path);
  }

  /// Inspecciona los bytes en memoria de un ELF.
  static ElfInfo inspect(final Uint8List bytes, {final String source = '<memoria>'}) {
    if (bytes.length < 52) {
      throw ElfFormatException('$source es demasiado pequeño para ser ELF '
          '(${bytes.length} bytes)');
    }
    if (bytes[0] != 0x7F ||
        bytes[1] != 0x45 || // E
        bytes[2] != 0x4C || // L
        bytes[3] != 0x46) {
      // F
      throw ElfFormatException('$source no tiene la firma ELF');
    }

    final elfClass = bytes[4];
    if (elfClass != 1 && elfClass != 2) {
      throw ElfFormatException('$source tiene e_ident[EI_CLASS] inválido ($elfClass)');
    }
    final is64 = elfClass == 2;

    final dataEncoding = bytes[5];
    if (dataEncoding != 1 && dataEncoding != 2) {
      throw ElfFormatException('$source tiene endianness inválida ($dataEncoding)');
    }
    final little = dataEncoding == 1;
    final endian = little ? Endian.little : Endian.big;
    final data = ByteData.sublistView(bytes);

    final machine = data.getUint16(0x12, endian);

    // Cabecera de programa: offset, tamaño de entrada y número de entradas.
    final int phoff;
    final int phentsize;
    final int phnum;
    if (is64) {
      phoff = data.getUint64(0x20, endian);
      phentsize = data.getUint16(0x36, endian);
      phnum = data.getUint16(0x38, endian);
    } else {
      phoff = data.getUint32(0x1C, endian);
      phentsize = data.getUint16(0x2A, endian);
      phnum = data.getUint16(0x2C, endian);
    }

    if (phnum == 0) {
      // Sin tabla de programas: no es un ejecutable cargable.
      throw ElfFormatException('$source no tiene tabla de programas (e_phnum = 0)');
    }
    final minEntrySize = is64 ? 56 : 32;
    if (phentsize < minEntrySize) {
      throw ElfFormatException('$source tiene phentsize $phentsize, '
          'mínimo esperado $minEntrySize para ELF${is64 ? 64 : 32}');
    }
    if (phoff <= 0 || phoff + phnum * phentsize > bytes.length) {
      throw ElfFormatException('$source tiene la tabla de programas fuera de rango '
          '(phoff=$phoff, phnum=$phnum, phentsize=$phentsize, tamaño=${bytes.length})');
    }

    final alignments = <int>[];
    String? interpreter;

    for (var i = 0; i < phnum; i++) {
      final base = phoff + i * phentsize;
      final type = data.getUint32(base, endian);

      if (type == _ptLoad) {
        final alignOffset = base + (is64 ? 0x30 : 0x1C);
        final align = is64
            ? data.getUint64(alignOffset, endian)
            : data.getUint32(alignOffset, endian);
        alignments.add(align);
      } else if (type == _ptInterp) {
        final int offset;
        final int size;
        if (is64) {
          offset = data.getUint64(base + 0x08, endian);
          size = data.getUint64(base + 0x20, endian);
        } else {
          offset = data.getUint32(base + 0x04, endian);
          size = data.getUint32(base + 0x10, endian);
        }
        if (size > 0 && offset >= 0 && offset + size <= bytes.length) {
          final raw = bytes.sublist(offset, offset + size);
          interpreter = String.fromCharCodes(
            raw.takeWhile((final b) => b != 0),
          );
        }
      }
    }

    return ElfInfo(
      is64Bit: is64,
      isLittleEndian: little,
      machine: machine,
      interpreter: interpreter,
      loadAlignments: alignments,
    );
  }
}
