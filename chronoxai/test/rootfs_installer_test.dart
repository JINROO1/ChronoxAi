import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chronoxai/data/runtime/oci_client.dart';
import 'package:chronoxai/data/runtime/rootfs_installer.dart';
import 'package:chronoxai/domain/terminal/linux_paths.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Servidor OCI de mentira: responde token, índice, manifiesto y blobs.
///
/// Se sustituye `http.Client`, no la lógica del instalador: así se comprueba el
/// flujo completo (índice multiarquitectura → capas → hash → extracción) sin red.
class RegistroFalso {
  RegistroFalso({required this.capas, this.arquitectura = 'arm64'});

  /// Contenido real (`tar.gz`) de cada capa.
  final List<List<int>> capas;

  final String arquitectura;

  /// Si se cambia a `true`, el blob servido se altera tras calcular el digest.
  ///
  /// Se añaden bytes al final en lugar de tocar el contenido: la capa sigue
  /// siendo gzip válido (el decodificador lo acepta), pero el sha256 ya no
  /// coincide, que es justo lo que se quiere comprobar.
  bool corromperCapa = false;

  int peticionesBlob = 0;

  String get _digestIndice => 'sha256:${sha256.convert(utf8.encode('indice'))}';

  List<Map<String, Object?>> get _descriptores => <Map<String, Object?>>[
        for (var i = 0; i < capas.length; i++)
          <String, Object?>{
            'mediaType': 'application/vnd.oci.image.layer.v1.tar+gzip',
            'digest': 'sha256:${sha256.convert(capas[i])}',
            'size': capas[i].length,
          },
      ];

  Map<String, Object?> get _manifiesto => <String, Object?>{
        'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': <String, Object?>{
          'mediaType': 'application/vnd.oci.image.config.v1+json',
          'digest': 'sha256:config',
          'size': 10,
        },
        'layers': _descriptores,
      };

  http.Client cliente() => _ClienteFalso(this);
}

class _ClienteFalso extends http.BaseClient {
  _ClienteFalso(this.registro);

  final RegistroFalso registro;

  @override
  Future<http.StreamedResponse> send(final http.BaseRequest request) async {
    final url = request.url;

    if (url.host == 'auth.docker.io') {
      return _json(<String, Object?>{'token': 'token-anonimo'});
    }

    if (url.path.endsWith('/manifests/bookworm')) {
      // Índice multiarquitectura con dos variantes: si el cliente se queda con
      // la primera (amd64) el test fallará al no encontrar capas válidas.
      return _json(<String, Object?>{
        'mediaType': 'application/vnd.oci.image.index.v1+json',
        'manifests': <Map<String, Object?>>[
          <String, Object?>{
            'mediaType': 'application/vnd.oci.image.manifest.v1+json',
            'digest': 'sha256:manifest-amd64',
            'platform': <String, Object?>{
              'architecture': 'amd64',
              'os': 'linux'
            },
          },
          <String, Object?>{
            'mediaType': 'application/vnd.oci.image.manifest.v1+json',
            'digest': 'sha256:manifest-arm64',
            'platform': <String, Object?>{
              'architecture': registro.arquitectura,
              'os': 'linux',
            },
          },
        ],
      });
    }

    if (url.path.contains('/manifests/')) {
      if (url.path.endsWith('manifest-amd64')) {
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{"layers":[]}')),
          200,
        );
      }
      return _json(registro._manifiesto);
    }

    if (url.path.contains('/blobs/')) {
      registro.peticionesBlob++;
      final digest = url.path.split('/').last.substring('sha256:'.length);
      final indice = registro._descriptores.indexWhere(
        (final d) => (d['digest']! as String).endsWith(digest),
      );
      if (indice < 0) {
        return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
      }
      var datos = registro.capas[indice];
      if (registro.corromperCapa && indice == 0) {
        // Ataque realista: el servidor devuelve una imagen **válida** pero
        // distinta de la anunciada. El gzip se descomprime sin error y el tar
        // se extrae sin problema; lo único que delata el cambio es el hash.
        // Si la verificación no existiera, esto instalaría código ajeno.
        datos = gzip.encode(
          construirTar(<String, String>{
            'bin/sh': '#!/bin/sh\necho comprometido\n',
          }),
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          datos.sublist(0, datos.length ~/ 2),
          datos.sublist(datos.length ~/ 2),
        ]),
        200,
      );
    }

    return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
  }

  http.StreamedResponse _json(final Object cuerpo) => http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(jsonEncode(cuerpo))),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
}

/// Construye un `tar` mínimo con un `/bin/sh` dentro.
Uint8List construirTar(final Map<String, String> ficheros) {
  final bytes = <int>[];

  void cabecera(final String nombre, final int tamano, final String tipo) {
    final h = Uint8List(512);
    void escribir(final int offset, final int longitud, final String valor) {
      final datos = utf8.encode(valor);
      for (var i = 0; i < longitud && i < datos.length; i++) {
        h[offset + i] = datos[i];
      }
    }

    escribir(0, 100, nombre);
    escribir(100, 8, '0000644\u0000');
    escribir(108, 8, '0000000\u0000');
    escribir(116, 8, '0000000\u0000');
    escribir(124, 12, '${tamano.toRadixString(8).padLeft(11, '0')}\u0000');
    escribir(136, 12, '00000000000\u0000');
    escribir(148, 8, '        ');
    escribir(156, 1, tipo);
    escribir(257, 8, 'ustar\u000000');

    var suma = 0;
    for (final byte in h) {
      suma += byte;
    }
    escribir(148, 8, suma.toRadixString(8).padLeft(6, '0'));
    bytes.addAll(h);
  }

  ficheros.forEach((final nombre, final contenido) {
    final datos = utf8.encode(contenido);
    cabecera(nombre, datos.length, '0');
    bytes.addAll(datos);
    bytes.addAll(List<int>.filled((512 - datos.length % 512) % 512, 0));
  });

  bytes.addAll(List<int>.filled(1024, 0));
  return Uint8List.fromList(bytes);
}

void main() {
  late Directory raiz;
  late LinuxPaths rutas;
  late List<int> capaBase;

  setUp(() async {
    raiz = await Directory.systemTemp.createTemp('instalador_test_');
    rutas = LinuxPaths(filesDir: raiz.path, distroId: 'debian-bookworm');
    await rutas.ensure();

    capaBase = gzip.encode(
      construirTar(<String, String>{
        'bin/sh': '#!/bin/sh\n',
        'etc/os-release': 'ID=debian\nVERSION_ID="12"\n',
      }),
    );
  });

  tearDown(() async {
    if (raiz.existsSync()) raiz.deleteSync(recursive: true);
  });

  RootfsInstaller instalador(final RegistroFalso registro) => RootfsInstaller(
        paths: rutas,
        registry: OciRegistryClient(
          baseUrl: 'registry-1.docker.io',
          repository: 'library/debian',
          clientFactory: registro.cliente,
        ),
        clientFactory: registro.cliente,
      );

  test('instala la capa arm64, no la amd64', () async {
    final registro = RegistroFalso(capas: <List<int>>[capaBase]);
    final resultado = await instalador(registro).install(architecture: 'arm64');

    expect(resultado.success, isTrue, reason: resultado.message);
    expect(
      File(p.join(rutas.rootfsDir, 'etc', 'os-release')).readAsStringSync(),
      contains('ID=debian'),
    );
    expect(rutas.looksInstalled, isTrue);
  });

  test('publica progreso de descarga y de extracción', () async {
    final registro = RegistroFalso(capas: <List<int>>[capaBase]);
    final fases = <InstallPhase>[];
    var mayorProgreso = 0.0;

    final resultado = await instalador(registro).install(
      architecture: 'arm64',
      onProgress: (final progreso) {
        if (fases.isEmpty || fases.last != progreso.phase) {
          fases.add(progreso.phase);
        }
        final fraccion = progreso.fraction;
        if (fraccion != null && fraccion > mayorProgreso)
          mayorProgreso = fraccion;
      },
    );

    expect(resultado.success, isTrue, reason: resultado.message);
    expect(
        fases,
        containsAllInOrder(<InstallPhase>[
          InstallPhase.resolving,
          InstallPhase.downloading,
          InstallPhase.extracting,
          InstallPhase.activating,
          InstallPhase.done,
        ]));
    expect(mayorProgreso, greaterThan(0.9));
  });

  test('compone varias capas en orden', () async {
    final segunda = gzip.encode(
      construirTar(<String, String>{'etc/extra.conf': 'añadido\n'}),
    );
    final registro = RegistroFalso(capas: <List<int>>[capaBase, segunda]);

    final resultado = await instalador(registro).install(architecture: 'arm64');

    expect(resultado.success, isTrue, reason: resultado.message);
    expect(
      File(p.join(rutas.rootfsDir, 'etc', 'extra.conf')).readAsStringSync(),
      'añadido\n',
    );
  });

  test('descarta la instalación si el hash de una capa no coincide', () async {
    final registro = RegistroFalso(capas: <List<int>>[capaBase])
      ..corromperCapa = true;

    final resultado = await instalador(registro).install(architecture: 'arm64');

    expect(resultado.success, isFalse);
    expect(
      resultado.message,
      contains('no coincide con su hash'),
      reason: 'el hash que no cuadra debe abortar antes de activar nada',
    );
    // Y sobre todo: el shell servido no debe haber llegado al rootfs.
    expect(
      File('${rutas.rootfsDir}/bin/sh').existsSync(),
      isFalse,
      reason: 'se activó contenido que no coincidía con el hash',
    );
    // Nada activado: el rootfs definitivo no existe.
    expect(rutas.looksInstalled, isFalse);
    expect(Directory('${rutas.rootfsDir}.partial').existsSync(), isFalse);
  });

  test('rechaza una imagen sin /bin/sh', () async {
    final sinShell = gzip.encode(
      construirTar(<String, String>{'etc/leeme.txt': 'sin shell\n'}),
    );
    final registro = RegistroFalso(capas: <List<int>>[sinShell]);

    final resultado = await instalador(registro).install(architecture: 'arm64');

    expect(resultado.success, isFalse);
    expect(resultado.message, contains('/bin/sh'));
    expect(rutas.looksInstalled, isFalse);
  });

  test('cancelar deja el sistema limpio y no activa nada', () async {
    final registro = RegistroFalso(capas: <List<int>>[capaBase]);
    final instaladorEnCurso = instalador(registro);

    final resultado = await instaladorEnCurso.install(
      architecture: 'arm64',
      // Se cancela en cuanto empieza la descarga, como haría el botón de la UI.
      onProgress: (final progreso) {
        if (progreso.phase == InstallPhase.downloading) {
          instaladorEnCurso.cancel();
        }
      },
    );

    expect(resultado.success, isFalse);
    expect(rutas.looksInstalled, isFalse);
    expect(Directory('${rutas.rootfsDir}.partial').existsSync(), isFalse);
  });

  test('una arquitectura no disponible da un mensaje claro', () async {
    final registro =
        RegistroFalso(capas: <List<int>>[capaBase], arquitectura: 's390x');

    final resultado = await instalador(registro).install(architecture: 'arm64');

    expect(resultado.success, isFalse);
    expect(resultado.message, contains('arm64'));
  });

  test('guarda los metadatos de la imagen instalada', () async {
    final registro = RegistroFalso(capas: <List<int>>[capaBase]);
    final instaladorFinal = instalador(registro);

    await instaladorFinal.install(architecture: 'arm64');

    final metadatos = instaladorFinal.installedImage();
    expect(metadatos, isNotNull);
    expect(metadatos!['architecture'], 'arm64');
    expect(metadatos['tag'], 'bookworm');
    expect(instaladorFinal.isInstalled, isTrue);
  });

  test('remove() borra el rootfs instalado', () async {
    final registro = RegistroFalso(capas: <List<int>>[capaBase]);
    final instaladorFinal = instalador(registro);

    await instaladorFinal.install(architecture: 'arm64');
    await instaladorFinal.remove();

    expect(rutas.looksInstalled, isFalse);
  });

  test('mapea la ABI de Android a la arquitectura OCI', () {
    expect(RootfsInstaller.architectureFor('arm64-v8a'), 'arm64');
    expect(RootfsInstaller.architectureFor('x86_64'), 'amd64');
    expect(RootfsInstaller.architectureFor('armeabi-v7a'), 'arm');
  });
}
