import 'dart:convert';
import 'dart:io';

import 'package:chronoxai/data/runtime/gzip_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('gunzip', () {
    test('descomprime el mismo texto que gzip de dart:io', () async {
      final texto = List<String>.generate(
        500,
        (final i) => 'Línea $i del archivo de prueba: ñandú, pingüino y €.',
      ).join('\n');
      final comprimido = gzip.encode(utf8.encode(texto));

      final salida = await gunzip(
        Stream<List<int>>.value(comprimido),
      ).expand((final c) => c).toList();

      expect(utf8.decode(salida), texto);
    });

    test('funciona troceando la entrada byte a byte', () async {
      final texto = 'abcdefghij' * 100;
      final comprimido = gzip.encode(utf8.encode(texto));

      // Trozos de 3 bytes: el decodificador debe mantener estado entre ellos.
      final trozos = <List<int>>[];
      for (var i = 0; i < comprimido.length; i += 3) {
        trozos.add(
          comprimido.sublist(i, (i + 3).clamp(0, comprimido.length)),
        );
      }

      final salida = await gunzip(
        Stream<List<int>>.fromIterable(trozos),
      ).expand((final c) => c).toList();

      expect(utf8.decode(salida), texto);
    });

    test('entrega la salida en varios trozos, no en uno gigante', () async {
      const tamano = 200 * 1024;
      final comprimido = gzip.encode(List<int>.filled(tamano, 0x41));

      final trozos = await gunzip(
        Stream<List<int>>.value(comprimido),
      ).toList();

      expect(trozos.length, greaterThan(1));
      expect(trozos.fold<int>(0, (final s, final t) => s + t.length), tamano);
    });

    test('la entrada vacía produce una salida vacía', () async {
      final salida = await gunzip(const Stream<List<int>>.empty()).toList();
      expect(salida, isEmpty);
    });

    test('un flujo corrupto emite error en lugar de datos basura', () async {
      final comprimido = gzip.encode(utf8.encode('texto'));

      // Se rompe la cabecera: gzip debe rechazarla.
      final roto = <int>[0x00, 0x01, 0x02, ...comprimido.sublist(3)];

      await expectLater(
        gunzip(Stream<List<int>>.value(roto)).toList(),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
