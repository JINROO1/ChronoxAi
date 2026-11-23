import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chronoxai/data/runtime/tar_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Constructor de `tar` para las pruebas.
///
/// Se escribe a mano en lugar de usar un paquete para que el test compruebe al
/// extractor contra el formato tal como lo define la especificación, sin que el
/// mismo código genere y consuma el archivo.
class ConstructorTar {
  final List<int> _bytes = <int>[];

  void _cabecera({
    required String nombre,
    int tamano = 0,
    String tipo = '0',
    String enlace = '',
    String? prefijo,
  }) {
    final cabecera = Uint8List(512);

    void escribir(final int offset, final int longitud, final String valor) {
      final datos = utf8.encode(valor);
      for (var i = 0; i < longitud && i < datos.length; i++) {
        cabecera[offset + i] = datos[i];
      }
    }

    void octal(final int offset, final int longitud, final int valor) {
      final texto = valor.toRadixString(8).padLeft(longitud - 1, '0');
      escribir(offset, longitud, texto);
    }

    escribir(0, 100, nombre);
    octal(100, 8, 0x1A4); // modo 0644
    octal(108, 8, 0);
    octal(116, 8, 0);
    octal(124, 12, tamano);
    octal(136, 12, 0);
    escribir(148, 8, '        ');
    escribir(156, 1, tipo);
    escribir(157, 100, enlace);
    escribir(257, 8, 'ustar\u000000');
    if (prefijo != null) escribir(345, 155, prefijo);

    var suma = 0;
    for (final byte in cabecera) {
      suma += byte;
    }
    escribir(148, 8, suma.toRadixString(8).padLeft(6, '0'));

    _bytes.addAll(cabecera);
  }

  void _contenido(final List<int> datos) {
    _bytes.addAll(datos);
    final relleno = (512 - (datos.length % 512)) % 512;
    _bytes.addAll(List<int>.filled(relleno, 0));
  }

  void directorio(final String nombre) => _cabecera(nombre: '$nombre/', tipo: '5');

  void fichero(final String nombre, final String contenido) {
    final datos = utf8.encode(contenido);
    _cabecera(nombre: nombre, tamano: datos.length);
    _contenido(datos);
  }

  void ficheroConTamano(final String nombre, final int tamano) {
    _cabecera(nombre: nombre, tamano: tamano);
    _contenido(List<int>.filled(tamano, 0x42));
  }

  void enlaceSimbolico(final String nombre, final String destino) =>
      _cabecera(nombre: nombre, tipo: '2', enlace: destino);

  void enlaceDuro(final String nombre, final String destino) =>
      _cabecera(nombre: nombre, tipo: '1', enlace: destino);

  void whiteout(final String nombre) => _cabecera(nombre: nombre, tipo: '0');

  /// Marca el directorio como opaco en OCI.
  void directorioOpaco(final String directorio) =>
      _cabecera(nombre: '$directorio/.wh..wh..opq', tipo: '0');

  /// Entrada PAX con una ruta que no cabe en los 100 bytes de la cabecera.
  void ficheroConRutaLarga(final String nombre, final String contenido) {
    final datos = utf8.encode(contenido);
    final registro = 'path=$nombre';
    final longitud = registro.length + 4; // dígitos + espacio + salto
    final texto = '$longitud $registro\n';
    final pax = utf8.encode(texto);

    _cabecera(nombre: 'PaxHeader', tamano: pax.length, tipo: 'x');
    _contenido(pax);
    _cabecera(nombre: 'truncado', tamano: datos.length);
    _contenido(datos);
  }

  Uint8List terminar() {
    _bytes.addAll(List<int>.filled(1024, 0));
    return Uint8List.fromList(_bytes);
  }

  Stream<List<int>> flujo({final int trozo = 700}) async* {
    final datos = terminar();
    for (var i = 0; i < datos.length; i += trozo) {
      yield datos.sublist(i, (i + trozo).clamp(0, datos.length));
    }
  }
}

void main() {
  late Directory raiz;

  setUp(() {
    raiz = await Directory.systemTemp.createTemp('tar_test_');
  });

  tearDown(() {
    if (raiz.existsSync()) raiz.deleteSync(recursive: true);
  });

  TarExtractor extractor(
    final Directory destino, {
    bool Function()? isCancelled,
    void Function(String)? onEntry,
  }) => TarExtractor(
    rootDirectory: destino.path,
    isCancelled: isCancelled,
    onEntry: onEntry,
  );

  test('extrae ficheros y directorios', () async {
    final tar = ConstructorTar()
      ..directorio('etc')
      ..fichero('etc/hostname', 'chronox\n')
      ..fichero('etc/os-release', 'ID=debian\n');

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    final aplicadas = await extractor(destino).extract(tar.flujo());

    expect(aplicadas, 3);
    expect(
      File(p.join(destino.path, 'etc', 'hostname')).readAsStringSync(),
      'chronox\n',
    );
    expect(
      File(p.join(destino.path, 'etc', 'os-release')).readAsStringSync(),
      'ID=debian\n',
    );
  });

  test('escribe ficheros grandes sin corromperlos', () async {
    final tar = ConstructorTar()..ficheroConTamano('bin/libc.so.6', 300 * 1024 + 37);

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await extractor(destino).extract(tar.flujo(trozo: 4096));

    final escrito = File(p.join(destino.path, 'bin', 'libc.so.6'));
    expect(escrito.lengthSync(), 300 * 1024 + 37);
    expect(escrito.readAsBytesSync().every((final b) => b == 0x42), isTrue);
  });

  test('crea enlaces simbólicos con su destino literal', () async {
    final tar = ConstructorTar()
      ..directorio('bin')
      ..enlaceSimbolico('bin/sh', '/usr/bin/dash');

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await extractor(destino).extract(tar.flujo());

    final enlace = Link(p.join(destino.path, 'bin', 'sh'));
    expect(enlace.existsSync(), isTrue);
    expect(enlace.targetSync(), '/usr/bin/dash');
  });

  test('copia los enlaces duros', () async {
    final tar = ConstructorTar()
      ..fichero('usr/bin/dash', '#!/bin/sh\n')
      ..enlaceDuro('bin/sh', 'usr/bin/dash');

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await extractor(destino).extract(tar.flujo());

    expect(
      File(p.join(destino.path, 'bin', 'sh')).readAsStringSync(),
      '#!/bin/sh\n',
    );
  });

  test('los whiteouts borran lo que había de capas anteriores', () async {
    final destino = Directory(p.join(raiz.path, 'rootfs'))
      ..createSync(recursive: true);
    File(p.join(destino.path, 'viejo.txt')).writeAsStringSync('anterior');
    Directory(p.join(destino.path, 'var', 'cache')).createSync(recursive: true);

    final tar = ConstructorTar()
      ..whiteout('.wh.viejo.txt')
      ..directorio('var')
      ..whiteout('var/.wh.cache');

    await extractor(destino).extract(tar.flujo());

    expect(File(p.join(destino.path, 'viejo.txt')).existsSync(), isFalse);
    expect(Directory(p.join(destino.path, 'var', 'cache')).existsSync(), isFalse);
  });

  test('el directorio opaco vacía su contenido previo', () async {
    final destino = Directory(p.join(raiz.path, 'rootfs'))
      ..createSync(recursive: true);
    final var = Directory(p.join(destino.path, 'var', 'log'))
      ..createSync(recursive: true);
    File(p.join(var.path, 'antiguo.log')).writeAsStringSync('x');

    final tar = ConstructorTar()..directorioOpaco('var/log');
    await extractor(destino).extract(tar.flujo());

    expect(Directory(var.path).existsSync(), isTrue);
    expect(Directory(var.path).listSync(), isEmpty);
  });

  test('rechaza rutas que se escapan del directorio destino', () async {
    final tar = ConstructorTar()..fichero('../fuera.txt', 'malicioso');

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await expectLater(
      extractor(destino).extract(tar.flujo()),
      throwsA(isA<TarFormatException>()),
    );
    expect(File(p.join(raiz.path, 'fuera.txt')).existsSync(), isFalse);
  });

  test('rechaza rutas absolutas', () async {
    final tar = ConstructorTar()..fichero('/etc/passwd', 'malicioso');

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await expectLater(
      extractor(destino).extract(tar.flujo()),
      throwsA(isA<TarFormatException>()),
    );
  });

  test('rechaza una cabecera con checksum incorrecto', () async {
    final tar = ConstructorTar()..fichero('ok.txt', 'x');
    final datos = tar.terminar();
    datos[10] = 0x99; // corrompe el nombre sin recalcular el checksum

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await expectLater(
      extractor(destino).extract(Stream<List<int>>.value(datos)),
      throwsA(isA<TarFormatException>()),
    );
  });

  test('una descarga truncada se detecta en lugar de dar un fichero a medias', () async {
    final tar = ConstructorTar()..fichero('grande.bin', 'x' * 4096);
    final datos = tar.terminar();
    final truncado = datos.sublist(0, datos.length - 2000);

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await expectLater(
      extractor(destino).extract(Stream<List<int>>.value(truncado)),
      throwsA(isA<TarFormatException>()),
    );
  });

  test('aplica rutas largas de las cabeceras PAX', () async {
    final larga =
        'usr/share/${List<String>.generate(12, (final i) => 'capa$i').join('/')}/fichero.txt';
    final tar = ConstructorTar()..ficheroConRutaLarga(larga, 'contenido');

    final destino = Directory(p.join(raiz.path, 'rootfs'));
    await extractor(destino).extract(tar.flujo());

    expect(
      File(p.join(destino.path, p.joinAll(larga.split('/')))).readAsStringSync(),
      'contenido',
    );
  });

  test('se detiene al cancelar', () async {
    final tar = ConstructorTar()
      ..fichero('a.txt', 'a')
      ..fichero('b.txt', 'b')
      ..fichero('c.txt', 'c');

    var vistas = 0;
    final destino = Directory(p.join(raiz.path, 'rootfs'));

    await expectLater(
      extractor(
        destino,
        isCancelled: () => vistas >= 1,
        onEntry: (final _) => vistas++,
      ).extract(tar.flujo()),
      throwsA(isA<StateError>()),
    );
    expect(File(p.join(destino.path, 'c.txt')).existsSync(), isFalse);
  });

  test('notifica las entradas aplicadas', () async {
    final tar = ConstructorTar()
      ..fichero('uno', '1')
      ..fichero('dos', '2');

    final nombres = <String>[];
    await extractor(
      Directory(p.join(raiz.path, 'rootfs')),
      onEntry: nombres.add,
    ).extract(tar.flujo());

    expect(nombres, <String>['uno', 'dos']);
  });
}
