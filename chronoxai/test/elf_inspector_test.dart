import 'dart:typed_data';

import 'package:chronoxai/domain/terminal/elf_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Construye un ELF64 sintético con los `PT_LOAD` y el `PT_INTERP` indicados.
///
/// No hace falta un binario real: el inspector solo lee la cabecera y la tabla de
/// programas, así que un ELF mínimo es suficiente y hace el test determinista.
Uint8List buildElf({
  required int machine,
  required List<int> loadAligns,
  String? interpreter,
  bool is64 = true,
  bool littleEndian = true,
}) {
  const headerSize = 64;
  const phentsize = 56;
  final phnum = loadAligns.length + (interpreter == null ? 0 : 1);
  final interpBytes = interpreter == null
      ? Uint8List(0)
      : Uint8List.fromList([...interpreter.codeUnits, 0]);
  final interpOffset = headerSize + phnum * phentsize;
  final total = interpOffset + interpBytes.length;

  final bytes = Uint8List(total);
  final data = ByteData.sublistView(bytes);
  final endian = littleEndian ? Endian.little : Endian.big;

  // e_ident
  bytes[0] = 0x7F;
  bytes[1] = 0x45; // E
  bytes[2] = 0x4C; // L
  bytes[3] = 0x46; // F
  bytes[4] = is64 ? 2 : 1;
  bytes[5] = littleEndian ? 1 : 2;
  bytes[6] = 1; // EV_CURRENT

  // e_type / e_machine
  data.setUint16(0x10, 2, endian); // ET_EXEC
  data.setUint16(0x12, machine, endian);

  // e_phoff / e_phentsize / e_phnum
  data.setUint64(0x20, headerSize, endian);
  data.setUint16(0x36, phentsize, endian);
  data.setUint16(0x38, phnum, endian);

  for (var i = 0; i < loadAligns.length; i++) {
    final base = headerSize + i * phentsize;
    data.setUint32(base, 1, endian); // PT_LOAD
    data.setUint64(base + 0x30, loadAligns[i], endian); // p_align
  }

  if (interpreter != null) {
    final base = headerSize + loadAligns.length * phentsize;
    data.setUint32(base, 3, endian); // PT_INTERP
    data.setUint64(base + 0x08, interpOffset, endian); // p_offset
    data.setUint64(base + 0x20, interpBytes.length, endian); // p_filesz
    bytes.setRange(interpOffset, total, interpBytes);
  }

  return bytes;
}

void main() {
  group('ElfInspector', () {
    test('detecta un binario alineado a 16 KB', () {
      final elf = buildElf(
        machine: emAarch64,
        loadAligns: [16384, 16384, 16384],
        interpreter: '/system/bin/linker64',
      );

      final info = ElfInspector.inspect(elf);

      expect(info.machine, emAarch64);
      expect(info.is64Bit, isTrue);
      expect(info.supports16KPages, isTrue);
      expect(info.minLoadAlignment, 16384);
      expect(info.isAndroidCompatible, isTrue);
      expect(info.interpreter, '/system/bin/linker64');
    });

    test('detecta un binario que fallará en dispositivos de 16 KB', () {
      final elf = buildElf(machine: emAarch64, loadAligns: [4096, 4096]);

      final info = ElfInspector.inspect(elf);

      expect(info.supports16KPages, isFalse);
      expect(info.minLoadAlignment, 4096);
    });

    test('un solo segmento mal alineado invalida el binario', () {
      final elf = buildElf(machine: emAarch64, loadAligns: [16384, 4096]);

      expect(ElfInspector.inspect(elf).supports16KPages, isFalse);
    });

    test('reconoce un binario estático', () {
      final elf = buildElf(machine: emAarch64, loadAligns: [16384]);

      expect(ElfInspector.inspect(elf).interpreter, isNull);
    });

    test('identifica x86_64 y arm32', () {
      expect(
        ElfInspector.inspect(buildElf(machine: emX8664, loadAligns: [16384]))
            .machineName,
        contains('x86_64'),
      );
      expect(
        ElfInspector.inspect(buildElf(machine: 0x28, loadAligns: [16384]))
            .isAndroidCompatible,
        isFalse,
      );
    });

    test('soporta big endian', () {
      final elf = buildElf(
        machine: emAarch64,
        loadAligns: [16384],
        littleEndian: false,
      );

      final info = ElfInspector.inspect(elf);
      expect(info.isLittleEndian, isFalse);
      expect(info.machine, emAarch64);
      expect(info.supports16KPages, isTrue);
    });

    test('rechaza ficheros que no son ELF', () {
      final notElf = Uint8List.fromList(List.filled(128, 0x41));
      expect(
        () => ElfInspector.inspect(notElf),
        throwsA(isA<ElfFormatException>()),
      );
    });

    test('rechaza un ELF sin tabla de programas', () {
      final elf = buildElf(machine: emAarch64, loadAligns: []);
      expect(
        () => ElfInspector.inspect(elf),
        throwsA(
          isA<ElfFormatException>().having(
            (final e) => e.message,
            'message',
            contains('tabla de programas'),
          ),
        ),
      );
    });

    test('rechaza una tabla de programas fuera de rango', () {
      final elf = buildElf(machine: emAarch64, loadAligns: [16384]);
      // e_phnum mentiroso: dice 90 entradas donde solo cabe 1.
      ByteData.sublistView(elf).setUint16(0x38, 90, Endian.little);

      expect(
        () => ElfInspector.inspect(elf),
        throwsA(isA<ElfFormatException>()),
      );
    });

    test('informa la cadena completa para diagnóstico', () {
      final elf = buildElf(machine: emAarch64, loadAligns: [4096]);
      final text = ElfInspector.inspect(elf).toString();

      expect(text, contains('arm64-v8a'));
      expect(text, contains('16K: false'));
    });
  });
}
