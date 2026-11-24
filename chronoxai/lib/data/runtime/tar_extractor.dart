import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Error al interpretar o aplicar una capa `tar`.
class TarFormatException implements Exception {
  const TarFormatException(this.message);

  final String message;

  @override
  String toString() => 'TarFormatException: $message';
}

/// Extrae un `tar` sin comprimir a un directorio, en streaming.
///
/// Se implementa a mano en lugar de delegar en un paquete por tres razones
/// concretas de este proyecto:
///
///  * Las capas vienen de la red y **no son de confianza**: hay que rechazar
///    rutas absolutas y `..` que se salgan del rootfs. Con un extractor opaco no
///    se puede garantizar.
///  * Hay que respetar los **whiteouts de OCI** (`.wh.fichero`), que son lo que
///    permite a una capa *borrar* algo de la anterior. Ignorarlos deja ficheros
///    que deberían haber desaparecido.
///  * El proceso corre en un móvil: se escribe a disco según llegan los bytes y
///    nunca se tiene la capa entera en memoria.
class TarExtractor {
  TarExtractor({
    required this.rootDirectory,
    this.onBytes,
    this.onEntry,
    this.isCancelled,
  });

  /// Directorio destino (se crea si no existe).
  final String rootDirectory;

  /// Progreso acumulado, en bytes descomprimidos leídos.
  final void Function(int bytes)? onBytes;

  /// Se llama por cada entrada aplicada.
  final void Function(String path)? onEntry;

  /// Permite abortar entre entradas.
  final bool Function()? isCancelled;

  late final String _root;
  int _bytes = 0;
  int _entries = 0;

  /// Entradas aplicadas hasta el momento.
  int get entries => _entries;

  /// Bytes descomprimidos consumidos.
  int get bytesRead => _bytes;

  StreamIterator<List<int>>? _iterator;
  final List<int> _buffer = <int>[];

  /// Extrae el `tar` de [stream] y devuelve el número de entradas aplicadas.
  ///
  /// Lanza [TarFormatException] si el flujo no es un tar válido y [StateError]
  /// si [isCancelled] devuelve `true`.
  Future<int> extract(final Stream<List<int>> stream) async {
    await Directory(rootDirectory).create(recursive: true);
    _root = Directory(rootDirectory).absolute.path;
    _iterator = StreamIterator<List<int>>(stream);

    String? pendingPath;
    String? pendingLink;

    while (true) {
      if (!await _fill(512)) break;
      if (_isZeroBlock(_buffer)) {
        // Un bloque de ceros es el final del archivo, pero un tar puede venir
        // concatenado: se comprueba el siguiente bloque.
        await _take(512);
        if (!await _fill(512)) break;
        if (_isZeroBlock(_buffer)) break;
        continue;
      }

      final header = _parseHeader(await _take(512));

      // Metadatos: describen la entrada siguiente y no se aplican.
      if (header.type == 'x' ||
          header.type == 'g' ||
          header.type == 'L' ||
          header.type == 'K') {
        final payload = await _take(header.size);
        await _skip(_padding(header.size));
        final text = utf8.decode(payload, allowMalformed: true);
        switch (header.type) {
          case 'L':
            pendingPath = text.split('\u0000').first;
          case 'K':
            pendingLink = text.split('\u0000').first;
          default:
            final fields = _parsePax(text);
            pendingPath = fields['path'] ?? pendingPath;
            pendingLink = fields['linkpath'] ?? pendingLink;
        }
        continue;
      }

      final name = pendingPath ?? header.name;
      final linkName = pendingLink ?? header.linkName;
      pendingPath = null;
      pendingLink = null;

      if (isCancelled?.call() ?? false) {
        throw StateError('Extracción cancelada');
      }

      final target = _safeJoin(name);

      // Los whiteouts se aplican siempre, aunque la entrada traiga contenido:
      // si no, un `.wh.` con datos acabaría escrito como fichero normal y el
      // borrado de la capa anterior no ocurriría.
      if (_isWhiteout(name)) {
        await _skip(header.size + _padding(header.size));
        await _applyWhiteout(name, target);
      } else if (header.isFile || header.size > 0) {
        // Contenido escrito según llega: un fichero de 40 MB no pasa por RAM.
        await _writeStream(target, header.size);
        await _skip(_padding(header.size));
      } else {
        await _applyMetadata(header, name, linkName, target);
      }

      _entries++;
      onEntry?.call(name);
      onBytes?.call(_bytes);
    }

    await _iterator?.cancel();
    _iterator = null;
    return _entries;
  }

  // ---------------------------------------------------------------------------
  // Lectura del flujo
  // ---------------------------------------------------------------------------

  Future<bool> _fill(final int count) async {
    while (_buffer.length < count) {
      final iterator = _iterator;
      if (iterator == null || !await iterator.moveNext()) return false;
      _buffer.addAll(iterator.current);
    }
    return true;
  }

  Future<Uint8List> _take(final int count) async {
    if (count == 0) return Uint8List(0);
    if (!await _fill(count)) {
      throw const TarFormatException(
        'El archivo terminó a media entrada: la descarga está incompleta.',
      );
    }
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    _bytes += count;
    return out;
  }

  Future<void> _skip(final int count) async {
    if (count == 0) return;
    if (!await _fill(count)) return;
    _buffer.removeRange(0, count);
    _bytes += count;
  }

  static int _padding(final int size) => (512 - (size % 512)) % 512;

  // ---------------------------------------------------------------------------
  // Aplicación de entradas
  // ---------------------------------------------------------------------------

  Future<void> _applyMetadata(
    final _TarHeader header,
    final String name,
    final String linkName,
    final String target,
  ) async {
    if (header.isDirectory) {
      await Directory(target).create(recursive: true);
      return;
    }

    if (header.isSymlink) {
      await Directory(p.dirname(target)).create(recursive: true);
      await _removeAny(target);
      // El destino del enlace se escribe tal cual: puede ser absoluto dentro del
      // contenedor (`/usr/bin/foo`), y eso es lo correcto aquí.
      await Link(target).create(linkName);
      return;
    }

    if (header.isHardLink) {
      final source = _safeJoin(linkName);
      await Directory(p.dirname(target)).create(recursive: true);
      await _removeAny(target);
      if (File(source).existsSync()) {
        // Un enlace duro real no se puede crear con `dart:io`; se copia el
        // contenido. Es más espacio, pero el resultado es equivalente para
        // ejecutar el contenedor.
        await File(source).copy(target);
      }
      return;
    }

    if (header.isFile) {
      await _writeFile(target, Uint8List(0));
    }
  }

  /// Trozos de 128 KiB: suficiente para amortizar el coste de E/S y pequeño como
  /// para no importar en un móvil.
  static const int _chunkSize = 128 * 1024;

  /// Escribe una entrada de tamaño [size] tomando los bytes del búfer por
  /// trozos, sin materializar el fichero completo en memoria.
  Future<void> _writeStream(final String target, final int size) async {
    await Directory(p.dirname(target)).create(recursive: true);
    await _removeAny(target);

    final sink = File(target).openWrite();
    try {
      var remaining = size;
      while (remaining > 0) {
        final chunk = remaining < _chunkSize ? remaining : _chunkSize;
        sink.add(await _take(chunk));
        remaining -= chunk;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<void> _writeFile(final String target, final Uint8List data) async {
    await Directory(p.dirname(target)).create(recursive: true);
    await _removeAny(target);
    await File(target).writeAsBytes(data, flush: false);
  }

  /// Aplica un whiteout de OCI.
  ///
  /// `.wh.<nombre>` borra esa entrada de las capas anteriores.
  /// `.wh..wh..opq` marca el directorio como *opaco*: oculta todo lo anterior.
  Future<void> _applyWhiteout(final String name, final String target) async {
    final base = p.basename(name);
    if (base == '.wh..wh..opq') {
      final dir = Directory(p.dirname(target));
      if (dir.existsSync()) {
        await for (final entity in dir.list()) {
          await _removeAny(entity.path);
        }
      }
      return;
    }
    // El prefijo es '.wh.' (cuatro caracteres, con el punto final incluido).
    // Recortar solo tres dejaba '.viejo.txt', con lo que el whiteout borraba
    // un fichero oculto que no existía y el original sobrevivía: las capas
    // nuevas no llegaban a eliminar nada de las anteriores.
    const prefijo = '.wh.';
    if (base.length <= prefijo.length) return;
    final borrar = base.substring(prefijo.length);
    await _removeAny(p.join(p.dirname(target), borrar));
  }

  Future<void> _removeAny(final String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      default:
        await File(path).delete();
    }
  }

  static bool _isWhiteout(final String name) =>
      p.basename(name).startsWith('.wh.');

  /// Une la ruta de la entrada con la raíz, rechazando cualquier escape.
  ///
  /// Es la defensa principal del extractor: una capa manipulada con
  /// `../../data/data/app.chronoxai/...` podría sobrescribir ficheros de la app.
  String _safeJoin(final String name) {
    if (name.isEmpty) {
      throw const TarFormatException('Entrada con nombre vacío.');
    }
    if (name.startsWith('/')) {
      throw TarFormatException('Ruta absoluta en el tar: "$name".');
    }
    final normalized = p.normalize(p.join(_root, name));
    if (!p.equals(normalized, _root) &&
        !normalized.startsWith('$_root${p.separator}')) {
      throw TarFormatException(
        'La entrada "$name" intenta salir del directorio de destino.',
      );
    }
    return normalized;
  }

  // ---------------------------------------------------------------------------
  // Interpretación de cabeceras
  // ---------------------------------------------------------------------------

  static bool _isZeroBlock(final List<int> bytes) {
    for (var i = 0; i < 512; i++) {
      if (bytes[i] != 0) return false;
    }
    return true;
  }

  static _TarHeader _parseHeader(final Uint8List header) {
    final expected = _parseNumber(header, 148, 8);
    var sum = 0;
    for (var i = 0; i < 512; i++) {
      sum += (i >= 148 && i < 156) ? 0x20 : header[i];
    }
    if (expected == null || sum != expected) {
      throw const TarFormatException(
        'Cabecera con checksum inválido: el flujo no parece un tar.',
      );
    }

    final name = _readString(header, 0, 100);
    final prefix = _readString(header, 345, 155);
    return _TarHeader(
      name: prefix.isEmpty ? name : '$prefix/$name',
      size: _parseNumber(header, 124, 12) ?? 0,
      type: String.fromCharCode(header[156]),
      linkName: _readString(header, 157, 100),
    );
  }

  static String _readString(
    final Uint8List bytes,
    final int offset,
    final int length,
  ) {
    var end = offset;
    final limit = offset + length;
    while (end < limit && bytes[end] != 0) {
      end++;
    }
    return utf8.decode(bytes.sublist(offset, end), allowMalformed: true);
  }

  static int? _parseNumber(
    final Uint8List bytes,
    final int offset,
    final int length,
  ) {
    final raw = bytes.sublist(offset, offset + length);
    if (raw.isNotEmpty && (raw[0] & 0x80) != 0) {
      // Base-256 (GNU): ficheros de más de 8 GB o rutas largas.
      var value = 0;
      for (var i = 1; i < raw.length; i++) {
        value = (value << 8) | raw[i];
      }
      return value;
    }

    final text = StringBuffer();
    for (final byte in raw) {
      if (byte == 0) break;
      text.writeCharCode(byte);
    }
    final trimmed = text.toString().trim();
    if (trimmed.isEmpty) return 0;
    return int.tryParse(trimmed, radix: 8);
  }

  static Map<String, String> _parsePax(final String text) {
    final fields = <String, String>{};
    var index = 0;
    while (index < text.length) {
      final space = text.indexOf(' ', index);
      if (space == -1) break;
      final length = int.tryParse(text.substring(index, space));
      if (length == null || length <= 0) break;
      final end = (index + length).clamp(0, text.length);
      final record = text.substring(space + 1, end);
      final equals = record.indexOf('=');
      if (equals > 0) {
        fields[record.substring(0, equals).trim()] =
            record.substring(equals + 1).replaceAll('\n', '');
      }
      index += length;
    }
    return fields;
  }
}

class _TarHeader {
  const _TarHeader({
    required this.name,
    required this.size,
    required this.type,
    required this.linkName,
  });

  final String name;
  final int size;
  final String type;
  final String linkName;

  bool get isFile => type == '0' || type == '\u0000' || type.isEmpty;
  bool get isDirectory => type == '5';
  bool get isSymlink => type == '2';
  bool get isHardLink => type == '1';
}
