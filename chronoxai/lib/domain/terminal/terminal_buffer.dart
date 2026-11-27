/// Modelo de pantalla de un terminal ANSI.
///
/// Es un parser de secuencias de escape **con estado**, no un `Text` que crece.
/// La diferencia importa: dentro del contenedor se ejecutan `nano`, `less`,
/// `top` y `apt`, que no escriben líneas nuevas sino que mueven el cursor,
/// borran líneas y repintan zonas. Un buffer acumulativo mostraría esos
/// programas como basura repetida.
///
/// Lo que soporta:
///
///  * texto UTF-8 (la decodificación de bytes a caracteres la hace el llamador,
///    porque un carácter partido entre dos trozos no se puede decodificar
///    aislado),
///  * control de cursor: `\n`, `\r`, `\b`, `\t`, `ESC[<n>A/B/C/D`,
///    `ESC[<fila>;<col>H`, `ESC[<col>G`, `ESC[<n>d`,
///  * borrado: `ESC[K`, `ESC[1K`, `ESC[2K`, `ESC[J`, `ESC[2J`,
///  * salto de línea automático (`ESC[?7h/l`) y modo de envoltura,
///  * guardar/restaurar cursor (`ESC7`/`ESC8` y `ESC[s`/`ESC[u`),
///  * colores SGR: se registran por celda para que la UI pueda pintarlos.
///
/// Lo que **no** soporta, a propósito: scrollback dentro de la región de scroll
/// (`ESC[r`), alfabeto alternativo completo y atributos como cursiva. Afectan a
/// programas de pantalla completa que necesitan un emulador entero; aquí el
/// coste supera al beneficio. Cuando llegan, se ignoran en lugar de romper el
/// resto del flujo, que es lo que hace que `nano` siga siendo usable.
library;

/// Color de una celda, como índice de ANSI (0-255).
class TerminalStyle {
  const TerminalStyle({this.foreground, this.background, this.bold = false});

  final int? foreground;
  final int? background;
  final bool bold;

  static const TerminalStyle def = TerminalStyle();

  bool get isDefault => foreground == null && background == null && !bold;

  TerminalStyle copyWith({
    int? foreground,
    int? background,
    bool? bold,
  }) =>
      TerminalStyle(
        foreground: foreground ?? this.foreground,
        background: background ?? this.background,
        bold: bold ?? this.bold,
      );

  @override
  bool operator ==(final Object other) =>
      other is TerminalStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(foreground, background, bold);
}

/// Una celda de la pantalla.
class TerminalCell {
  const TerminalCell({this.char = ' ', this.style = TerminalStyle.def});

  final String char;
  final TerminalStyle style;

  static const TerminalCell vacia = TerminalCell();
}

/// Una línea visible, ya recortada por la derecha.
class TerminalLine {
  TerminalLine(this.cells, {this.style = TerminalStyle.def});

  final List<TerminalCell> cells;

  /// Estilo con el que se rellenan las columnas vacías al pintar.
  final TerminalStyle style;

  String get text => cells.map((final c) => c.char).join();

  bool get isBlank => text.trim().isEmpty;
}

/// Emulador de pantalla.
///
/// [columns] y [rows] son el tamaño con el que se envuelve. El invitado cree
/// iniciar con 80 columnas, así que por defecto se usa 80; el
/// número de filas solo limita cuánto se recuerda.
class TerminalBuffer {
  TerminalBuffer({this.columns = 80, this.rows = 1000})
      : _lines = <List<TerminalCell>>[<TerminalCell>[]];

  final int columns;
  final int rows;

  /// Líneas completadas más la línea en curso.
  final List<List<TerminalCell>> _lines;

  int _row = 0;
  int _col = 0;

  TerminalStyle _style = TerminalStyle.def;
  bool _autoWrap = true;

  /// Cursor guardado por `ESC 7` / `ESC 8`.
  ({int row, int col, TerminalStyle style})? _saved;

  /// Estado del parser entre llamadas.
  _ParseState _state = _ParseState.ground;
  final StringBuffer _params = StringBuffer();

  /// LÍNEA DE ESTADO: texto que aún no se ha cerrado con `\n`.
  ///
  /// La UI lo necesita aparte porque tiene que decidir si el prompt está «a
  /// medias» para pintar el cursor ahí en lugar de al principio de una línea
  /// nueva.
  String get currentLine {
    final cells = _lines[_row];
    return cells.map((final c) => c.char).join().trimRight();
  }

  /// Número de líneas completadas antes de la línea en curso.
  int get completedLines => _row;

  /// Cursor, en coordenadas de pantalla (0-based).
  int get cursorRow => _row;
  int get cursorCol => _col;

  /// true si el cursor está en la línea en curso (lo normal). Es false solo si
  /// se ha movido a una fila anterior con una secuencia de escape.
  bool get cursorOnLastLine => _row == _lines.length - 1;

  /// Aplica bytes tal y como llegan del proceso.
  ///
  /// La decodificación es incremental a propósito: un carácter UTF-8 partido
  /// entre dos trozos de 8 KB se decodificaría como basura si cada trozo se
  /// tratara por separado, y eso pasa constantemente con tildes y con el marco
  /// de `nano`.
  void writeBytes(final List<int> bytes) {
    if (bytes.isEmpty) return;
    // `allowMalformed` evita que un byte suelto de una secuencia de escape
    // binaria (algunos programas escriben UCS-2 crudo) tumbe la sesión.
    writeText(_decoder.convert(bytes));
  }

  /// Aplica texto ya decodificado. Es lo que usan las pruebas.
  void writeText(final String data) {
    for (final rune in data.runes) {
      _feed(rune);
    }
  }

  final _Decoder _decoder = _Decoder();

  /// Aplica un carácter o el resultado de una secuencia.
  void _feed(final int rune) {
    switch (_state) {
      case _ParseState.ground:
        if (rune == 0x1B) {
          _state = _ParseState.escape;
        } else if (rune < 0x20) {
          _control(rune);
        } else if (rune == 0x7F) {
          // DEL: se ignora, como hacen los terminales reales.
        } else {
          _putChar(String.fromCharCode(rune));
        }
      case _ParseState.escape:
        switch (rune) {
          case 0x5B: // '['
            _params.clear();
            _state = _ParseState.csi;
          case 0x5D: // ']' — OSC: título de ventana u otras; se ignora hasta BEL o ST
            _state = _ParseState.osc;
          case 0x37: // '7' guardar cursor
            _saveCursor();
            _state = _ParseState.ground;
          case 0x38: // '8' restaurar cursor
            _restoreCursor();
            _state = _ParseState.ground;
          default:
            // '(', ')', '#', '=' y similares: secuencias de un carácter que no
            // cambian la pantalla en este emulador.
            _state = _ParseState.ground;
        }
      case _ParseState.csi:
        if (rune >= 0x40 && rune <= 0x7E) {
          _state = _ParseState.ground;
          _applyCsi(String.fromCharCode(rune), _params.toString());
        } else if (rune == 0x3B ||
            (rune >= 0x30 && rune <= 0x39) ||
            rune == 0x3F ||
            rune == 0x20) {
          _params.writeCharCode(rune);
        } else if (rune == 0x1B) {
          _state = _ParseState.escape;
        } else if (rune < 0x20) {
          _control(rune);
        }
      case _ParseState.osc:
        // Termina con BEL o con ESC \. El contenido (título, hipervínculos) no
        // se representa en una terminal de texto.
        if (rune == 0x07) {
          _state = _ParseState.ground;
        } else if (rune == 0x1B) {
          _state = _ParseState.oscEscape;
        }
      case _ParseState.oscEscape:
        _state = rune == 0x5C ? _ParseState.ground : _ParseState.osc;
    }
  }

  // ---------------------------------------------------------------------------
  // Control de caracteres
  // ---------------------------------------------------------------------------

  void _control(final int code) {
    switch (code) {
      case 0x0A: // LF
        _newLine();
      case 0x0D: // CR
        _col = 0;
      case 0x08: // BS
        if (_col > 0) _col--;
      case 0x09: // TAB
        final next = ((_col ~/ 8) + 1) * 8;
        for (var c = _col; c < next && c < columns; c++) {
          _putChar(' ');
        }
      default:
        break; // BEL, NUL, etc.: sin efecto visible
    }
  }

  void _newLine() {
    // Al bajar de la última línea se recorta por arriba: se guarda todo el
    // histórico hasta [rows] y a partir de ahí se descarta lo más viejo.
    if (_row >= rows - 1) {
      // Se descarta un bloque de golpe, no línea a línea: con el historial
      // lleno, mover la lista en cada salto de línea hace que `cat` de un
      // fichero grande se arrastre.
      final descartar = _row - (rows ~/ 2);
      if (descartar > 0) {
        _lines.removeRange(0, descartar);
        _row -= descartar;
      }
    }
    _row++;
    while (_lines.length <= _row) {
      _lines.add(<TerminalCell>[]);
    }
    _col = 0;
  }

  void _putChar(final String char) {
    // El salto de línea automático ocurre al escribir el carácter que ya no
    // cabe, no al llenar la última columna: así el cursor reposa sobre la
    // columna 80 hasta que llega el siguiente. Es lo que hacen los terminales
    // reales y lo que esperan `nano` y `less` (que colocan el cursor con
    // ESC[<col>G y luego borran la línea).
    if (_col >= columns) {
      if (_autoWrap) {
        _newLine();
      } else {
        _col = columns - 1;
      }
    }
    final cells = _lines[_row];
    while (cells.length <= _col) {
      cells.add(TerminalCell.vacia);
    }
    cells[_col] = TerminalCell(char: char, style: _style);
    // En la última columna el cursor reposa ahí (con autoWrap se sale de la
    // fila, que es la señal de «pendiente de envolver»).
    if (_col < columns - 1) {
      _col++;
    } else if (_autoWrap) {
      _col = columns;
    }
  }

  // ---------------------------------------------------------------------------
  // Secuencias CSI
  // ---------------------------------------------------------------------------

  void _applyCsi(final String comando, final String parametros) {
    final privado = parametros.startsWith('?');
    final limpio = privado ? parametros.substring(1) : parametros;
    final numeros =
        limpio.split(';').map((final p) => int.tryParse(p) ?? 0).toList();
    final primero = numeros.isEmpty ? 0 : numeros.first;

    switch (comando) {
      case 'A':
        _row =
            (_row - (primero == 0 ? 1 : primero)).clamp(0, _lines.length - 1);
      case 'B':
        final destino = _row + (primero == 0 ? 1 : primero);
        _row = destino.clamp(0, _lines.length - 1);
      case 'C':
        _col = (_col + (primero == 0 ? 1 : primero)).clamp(0, columns - 1);
      case 'D':
        _col = (_col - (primero == 0 ? 1 : primero)).clamp(0, columns - 1);
      case 'E':
        _row =
            (_row + (primero == 0 ? 1 : primero)).clamp(0, _lines.length - 1);
        _col = 0;
      case 'F':
        _row =
            (_row - (primero == 0 ? 1 : primero)).clamp(0, _lines.length - 1);
        _col = 0;
      case 'G':
        _col = ((primero == 0 ? 1 : primero) - 1).clamp(0, columns - 1);
      case 'd':
        _col = 0;
        _row = ((primero == 0 ? 1 : primero) - 1).clamp(0, _lines.length - 1);
      case 'H' || 'f':
        final fila =
            (numeros.isNotEmpty && numeros[0] != 0) ? numeros[0] - 1 : 0;
        final columna =
            (numeros.length > 1 && numeros[1] != 0) ? numeros[1] - 1 : 0;
        _asegurarLinea(fila);
        _row = fila.clamp(0, _lines.length - 1);
        _col = columna.clamp(0, columns - 1);
      case 'J':
        _borrarPantalla(primero);
      case 'K':
        _borrarLinea(primero);
      case 'm':
        _aplicarSgr(numeros);
      case 'h' || 'l':
        if (privado && limpio == '7') {
          _autoWrap = comando == 'h';
        }
      case 's':
        _saveCursor();
      case 'u':
        _restoreCursor();
      default:
        // 'r' (región de scroll), 'n', 'c', 't'… se ignoran: no mantienen
        // estado propio aquí y romper el flujo por ellos estropearía el resto.
        break;
    }
  }

  void _asegurarLinea(final int fila) {
    while (_lines.length <= fila) {
      _lines.add(<TerminalCell>[]);
    }
  }

  void _borrarLinea(final int modo) {
    final cells = _lines[_row];
    // `_col` vale `columns` mientras el cursor reposa en la última columna; en
    // ese caso no hay celda del cursor que borrar y el barrido no toca nada.
    final desde = _col.clamp(0, columns - 1);
    switch (modo) {
      case 0: // desde el cursor hasta el final
        if (desde < cells.length) cells.removeRange(desde, cells.length);
      case 1: // desde el principio, incluida la celda del cursor
        final hasta = (_col < columns ? _col + 1 : columns);
        for (var i = 0; i < hasta && i < cells.length; i++) {
          cells[i] = TerminalCell.vacia;
        }
      case 2: // línea completa
        cells.clear();
      default:
        break;
    }
  }

  void _borrarPantalla(final int modo) {
    switch (modo) {
      case 0:
        _borrarLinea(0);
        _lines.removeRange(_row + 1, _lines.length);
      case 1:
        _borrarLinea(1);
        for (var i = 0; i < _row; i++) {
          _lines[i].clear();
        }
      case 2 || 3:
        _lines.clear();
        _lines.add(<TerminalCell>[]);
        _row = 0;
        _col = 0;
      default:
        break;
    }
  }

  void _aplicarSgr(final List<int> codigos) {
    if (codigos.isEmpty || (codigos.length == 1 && codigos.first == 0)) {
      _style = TerminalStyle.def;
      return;
    }
    var i = 0;
    while (i < codigos.length) {
      final codigo = codigos[i];
      switch (codigo) {
        case 0:
          _style = TerminalStyle.def;
        case 1:
          _style = _style.copyWith(bold: true);
        case 22:
          _style = TerminalStyle(
              foreground: _style.foreground, background: _style.background);
        case >= 30 && <= 37:
          _style = _style.copyWith(foreground: codigo - 30);
        case 39:
          _style =
              TerminalStyle(background: _style.background, bold: _style.bold);
        case >= 40 && <= 47:
          _style = _style.copyWith(background: codigo - 40);
        case 49:
          _style =
              TerminalStyle(foreground: _style.foreground, bold: _style.bold);
        case >= 90 && <= 97:
          _style = _style.copyWith(foreground: codigo - 90 + 8);
        case >= 100 && <= 107:
          _style = _style.copyWith(background: codigo - 100 + 8);
        case 38 || 48:
          // Color extendido: 38;5;N (paleta) o 38;2;R;G;B (RGB directo).
          if (i + 1 < codigos.length) {
            final tipo = codigos[i + 1];
            if (tipo == 5 && i + 2 < codigos.length) {
              _style = codigo == 38
                  ? _style.copyWith(foreground: codigos[i + 2])
                  : _style.copyWith(background: codigos[i + 2]);
              i += 2;
            } else if (tipo == 2 && i + 4 < codigos.length) {
              // RGB directo: se aproxima al índice de la paleta de 256 colores
              // para no tener que guardar tres componentes por celda.
              final r = codigos[i + 2];
              final g = codigos[i + 3];
              final b = codigos[i + 4];
              final indice = 16 + (r ~/ 43) * 36 + (g ~/ 43) * 6 + (b ~/ 43);
              _style = codigo == 38
                  ? _style.copyWith(foreground: indice)
                  : _style.copyWith(background: indice);
              i += 4;
            }
          }
        default:
          break;
      }
      i++;
    }
  }

  // ---------------------------------------------------------------------------
  // Cursor guardado
  // ---------------------------------------------------------------------------

  void _saveCursor() => _saved = (row: _row, col: _col, style: _style);

  void _restoreCursor() {
    final guardado = _saved;
    if (guardado == null) return;
    // Restaurar no debe sacar el cursor fuera del historial que existe: si la
    // fila guardada ya se recortó por límite de buffer, se queda en la última.
    _asegurarLinea(guardado.row);
    _row = guardado.row.clamp(0, _lines.length - 1);
    _col = guardado.col.clamp(0, columns);
    _style = guardado.style;
  }

  // ---------------------------------------------------------------------------
  // Lectura para la UI
  // ---------------------------------------------------------------------------

  /// Líneas que debe pintar la UI.
  ///
  /// Se recortan las vacías del principio (desplazamiento de shell) pero se
  /// conserva siempre la línea en curso, aunque esté vacía: es donde va el
  /// cursor del prompt.
  /// Filas que se han recortado por arriba en [lines].
  ///
  /// El cursor es absoluto (contando desde el principio del historial); quien
  /// pinte [lines] tiene que restarle esto para colocar el cursor en su sitio.
  /// Sin este dato, la única opción era suponer que el cursor está en la última
  /// línea, y por eso el cursor aparecía al final incluso editando en mitad de
  /// la pantalla.
  int get lineOffset {
    var inicio = 0;
    while (inicio < _row && _lines[inicio].isEmpty) {
      inicio++;
    }
    return inicio;
  }

  List<TerminalLine> get lines {
    final inicio = lineOffset;
    return <TerminalLine>[
      for (var i = inicio; i < _lines.length; i++)
        TerminalLine(
          List<TerminalCell>.unmodifiable(_recortar(_lines[i])),
        ),
    ];
  }

  List<TerminalCell> _recortar(final List<TerminalCell> cells) {
    var fin = cells.length;
    while (fin > 0 &&
        cells[fin - 1].char == ' ' &&
        cells[fin - 1].style.isDefault) {
      fin--;
    }
    return cells.sublist(0, fin);
  }

  /// Vacía la pantalla y el historial.
  void clear() {
    _lines.clear();
    _lines.add(<TerminalCell>[]);
    _row = 0;
    _col = 0;
    _style = TerminalStyle.def;
    _state = _ParseState.ground;
    _params.clear();
  }
}

enum _ParseState { ground, escape, csi, osc, oscEscape }

/// Decodificador UTF-8 que conserva los bytes incompletos entre trozos.
///
/// `Utf8Decoder` de `dart:io` no permite reanudar: `convert` falla o sustituye
/// el carácter si la secuencia viene partida. Aquí se guarda el prefijo válido
/// pendiente y se retoma con el trozo siguiente.
class _Decoder {
  final List<int> _pendiente = <int>[];

  String convert(final List<int> bytes) {
    final todos = _pendiente.isEmpty ? bytes : <int>[..._pendiente, ...bytes];
    _pendiente.clear();
    if (todos.isEmpty) return '';

    final buffer = StringBuffer();
    var i = 0;
    while (i < todos.length) {
      final byte = todos[i];
      final longitud = switch (byte) {
        <= 0x7F => 1,
        >= 0xC2 && <= 0xDF => 2,
        >= 0xE0 && <= 0xEF => 3,
        >= 0xF0 && <= 0xF4 => 4,
        // Byte de continuación suelto o inicial inválido: se descarta. Es lo
        // que haría un terminal real, que no puede representarlo.
        _ => 0,
      };
      if (longitud == 0) {
        i++;
        continue;
      }
      if (i + longitud > todos.length) {
        // Secuencia incompleta: se guarda para el próximo trozo.
        _pendiente.addAll(todos.sublist(i));
        break;
      }
      final punto = _codificar(todos.sublist(i, i + longitud), longitud);
      if (punto == null) {
        i += longitud;
        continue;
      }
      buffer.writeCharCode(punto);
      i += longitud;
    }
    return buffer.toString();
  }

  int? _codificar(final List<int> secuencia, final int longitud) {
    final primero = secuencia.first;
    var valor = switch (longitud) {
      1 => primero,
      2 => primero & 0x1F,
      3 => primero & 0x0F,
      _ => primero & 0x07,
    };
    for (var k = 1; k < longitud; k++) {
      final byte = secuencia[k];
      if (byte & 0xC0 != 0x80) return null;
      valor = (valor << 6) | (byte & 0x3F);
    }
    // Fuera de rango Unicode o par sustituto: no se puede representar.
    if (valor > 0x10FFFF || (valor >= 0xD800 && valor <= 0xDFFF)) return null;
    return valor;
  }
}
