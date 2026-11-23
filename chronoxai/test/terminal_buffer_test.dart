import 'dart:convert';

import 'package:chronoxai/domain/terminal/terminal_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('texto y control', () {
    test('escribe texto y separa líneas con LF', () {
      final buffer = TerminalBuffer()..writeText('uno\ndos\ntres');
      final lineas = buffer.lines.map((final l) => l.text).toList();
      expect(lineas, <String>['uno', 'dos', 'tres']);
    });

    test('CR vuelve al principio de la línea', () {
      final buffer = TerminalBuffer()..writeText('abc\rXY');
      expect(buffer.lines.last.text, 'XYc');
    });

    test('el progreso con CR sobrescribe en lugar de acumular', () {
      // Es el caso de apt, que repinta el porcentaje.
      final buffer = TerminalBuffer()
        ..writeText('0 %\r')
        ..writeText('50 %\r')
        ..writeText('100 %');
      expect(buffer.lines.length, 1);
      expect(buffer.lines.first.text, '100 %');
    });

    test('el tabulador avanza a múltiplos de 8', () {
      final buffer = TerminalBuffer()..writeText('a\tb');
      expect(buffer.lines.first.text, 'a       b');
    });

    test('el retroceso borra la posición del cursor', () {
      final buffer = TerminalBuffer()..writeText('abc\bX');
      expect(buffer.lines.first.text, 'abX');
    });

    test('envuelve a las 80 columnas y deja el cursor al final', () {
      final buffer = TerminalBuffer()..writeText('x' * 100);
      expect(buffer.lines.first.text.length, 80);
      expect(buffer.lines[1].text, 'x' * 20);
    });
  });

  group('secuencias ANSI', () {
    test('ESC[K borra desde el cursor', () {
      final buffer = TerminalBuffer()..writeText('abcdef\r\x1B[3D\x1B[K');
      expect(buffer.lines.first.text, 'abc');
    });

    test('ESC[2K borra la línea completa', () {
      final buffer = TerminalBuffer()..writeText('basura\x1B[2K');
      expect(buffer.lines.first.text, '');
    });

    test('mover el cursor arriba y reescribir pinta encima', () {
      final buffer = TerminalBuffer()
        ..writeText('primera\nsegunda')
        ..writeText('\x1B[1A\rRE');
      expect(buffer.lines[0].text, 'REimera');
    });

    test('ESC[H lleva a la esquina superior izquierda', () {
      final buffer = TerminalBuffer()
        ..writeText('uno\ndos\n')
        ..writeText('\x1B[1;1HX');
      expect(buffer.lines.first.text, 'Xno');
    });

    test('ESC[J desde el cursor no toca lo anterior', () {
      final buffer = TerminalBuffer()
        ..writeText('uno\ndos\ntres\r\x1B[2A\x1B[J');
      expect(buffer.lines.length, lessThanOrEqualTo(2));
    });

    test('SGR guarda el color de cada celda', () {
      final buffer = TerminalBuffer()..writeText('\x1B[31mrojo\x1B[0m normal');
      final celdas = buffer.lines.first.cells;
      expect(celdas[0].style.foreground, 1);
      // El espacio entre ambas palabras ya viene del estilo por defecto.
      final indiceNormal = buffer.lines.first.text.indexOf('normal');
      expect(celdas[indiceNormal].style.foreground, isNull);
    });

    test('SGR 38;5;N usa la paleta extendida', () {
      final buffer = TerminalBuffer()..writeText('\x1B[38;5;208mX\x1B[0m');
      expect(buffer.lines.first.cells.first.style.foreground, 208);
    });

    test('SGR 1 marca negrita sin perder el color', () {
      final buffer = TerminalBuffer()..writeText('\x1B[32;1mX');
      final estilo = buffer.lines.first.cells.first.style;
      expect(estilo.foreground, 2);
      expect(estilo.bold, isTrue);
    });

    test('una secuencia partir en dos trozos no rompe la pantalla', () {
      final buffer = TerminalBuffer()
        ..writeText('a\x1B[3')
        ..writeText('1mb');
      expect(buffer.lines.first.text, 'ab');
      expect(buffer.lines.first.cells[1].style.foreground, 1);
    });

    test('el título OSC se ignora sin ensuciar la salida', () {
      final buffer = TerminalBuffer()..writeText('\x1B]0;mi titulo\x07ok');
      expect(buffer.lines.first.text, 'ok');
    });

    test('las flechas (CSI A/B/C/D) no escriben nada', () {
      final buffer = TerminalBuffer()..writeText('\x1B[A\x1B[B\x1B[C\x1B[Dok');
      expect(buffer.lines.first.text, 'ok');
    });

    test('guardar y restaurar el cursor', () {
      final buffer = TerminalBuffer()..writeText('abc\x1B7XY\x1B8Z');
      // Se guarda tras escribir "abc", se escribe "XY" encima y se restaura:
      // la "Z" cae en la posición guardada.
      expect(buffer.lines.first.text, 'abcZ');
    });
  });

  group('decodificación UTF-8 incremental', () {
    test('una tilde partida entre trozos se decodifica entera', () {
      final bytes = utf8.encode('ñandú');
      final buffer = TerminalBuffer();
      // Se parte justo después del primer byte de la 'ñ' (2 bytes).
      buffer.writeBytes(bytes.sublist(0, 1));
      buffer.writeBytes(bytes.sublist(1));
      expect(buffer.lines.first.text, 'ñandú');
    });

    test('un emoji de 4 bytes partido en dos trozos sale correcto', () {
      final bytes = utf8.encode('ok 🚀');
      final buffer = TerminalBuffer();
      for (final byte in bytes) {
        buffer.writeBytes(<int>[byte]);
      }
      expect(buffer.lines.first.text, 'ok 🚀');
    });

    test('un byte inválido se descarta sin tirar el resto', () {
      final buffer = TerminalBuffer()..writeBytes(<int>[0x41, 0xFF, 0x42]);
      expect(buffer.lines.first.text, 'AB');
    });
  });

  group('historial', () {
    test('descarta las líneas vacías iniciales', () {
      final buffer = TerminalBuffer()..writeText('\n\n\nhola');
      final lineas = buffer.lines;
      expect(lineas.length, 1);
      expect(lineas.first.text, 'hola');
    });

    test('respeta el límite de filas descartando lo más antiguo', () {
      final buffer = TerminalBuffer(rows: 20);
      for (var i = 0; i < 200; i++) {
        buffer.writeText('linea $i\n');
      }
      final texto = buffer.lines.map((final l) => l.text).join('\n');
      expect(texto, contains('linea 199'));
      expect(texto, isNot(contains('linea 0\n')));
    });

    test('clear() vacía pantalla y estado', () {
      final buffer = TerminalBuffer()..writeText('algo\nmás');
      buffer.clear();
      expect(buffer.lines, hasLength(1));
      expect(buffer.lines.first.text, '');
    });
  });
}
