import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/runtime/pty_session.dart';
import '../../domain/terminal/terminal_buffer.dart';
import 'terminal_controller.dart';

/// Paleta de los 16 colores básicos de ANSI.
///
/// Se usa la de xterm, que es la que esperan `ls --color`, `git` y `nano`; los
/// colores 16-255 se aproximan al mismo tono con la paleta de 256.
const List<Color> _ansi = <Color>[
  Color(0xFF14161C), // negro
  Color(0xFFFF5C7A), // rojo
  Color(0xFF5AE08B), // verde
  Color(0xFFFFB454), // amarillo
  Color(0xFF8B7BFF), // azul
  Color(0xFFD07BFF), // magenta
  Color(0xFF4DE1C1), // cian
  Color(0xFFC8D0E0), // blanco
  Color(0xFF5C6478), // gris (brillante negro)
  Color(0xFFFF8AA0), // rojo brillante
  Color(0xFF8CF0AF), // verde brillante
  Color(0xFFFFD08A), // amarillo brillante
  Color(0xFFB0A6FF), // azul brillante
  Color(0xFFE6A8FF), // magenta brillante
  Color(0xFF8FF0DC), // cian brillante
  Color(0xFFEDF1F7), // blanco brillante
];

/// Color de una celda.
Color _color(final int? indice, {required final Color porDefecto}) {
  if (indice == null) return porDefecto;
  if (indice < 16) return _ansi[indice];
  if (indice < 232) {
    // Cubo de 6×6×6 que define xterm para los índices 16-231.
    final n = indice - 16;
    final r = (n ~/ 36) * 51;
    final g = ((n % 36) ~/ 6) * 51;
    final b = (n % 6) * 51;
    return Color.fromARGB(255, r, g, b);
  }
  // Escala de grises 232-255.
  final gris = 8 + (indice - 232) * 10;
  return Color.fromARGB(255, gris, gris, gris);
}

/// Terminal interactivo.
///
/// Se dibuja con `RichText` por línea en lugar de un `TextField`: cada celda
/// puede tener su color y su estilo, y el texto no se puede editar con el
/// cursor de Flutter porque quien manda es el shell del invitado.
class TerminalView extends StatefulWidget {
  const TerminalView({
    super.key,
    required this.controller,
    this.fontSize = 12.5,
  });

  final TerminalController controller;
  final double fontSize;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _entrada = TextEditingController();
  final FocusNode _foco = FocusNode();
  int _lineasPrevias = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_alCambiar);
    WidgetsBinding.instance.addPostFrameCallback((final _) => _foco.requestFocus());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_alCambiar);
    _scroll.dispose();
    _entrada.dispose();
    _foco.dispose();
    super.dispose();
  }

  void _alCambiar() {
    if (!mounted) return;
    setState(() {});
    // Solo se desplaza si han llegado líneas nuevas; si no, mover el scroll
    // mientras el usuario lee el historial resulta desesperante.
    final actuales = widget.controller.state.lines.length;
    if (actuales != _lineasPrevias) {
      _lineasPrevias = actuales;
      WidgetsBinding.instance.addPostFrameCallback((final _) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  /// Envía el texto del campo al proceso y lo vacía.
  ///
  /// Se vacía siempre, aunque el envío falle: dejar el texto en el campo haría
  /// que el usuario lo reenviara sin querer al reintentar.
  Future<void> _enviar(final String texto) async {
    _entrada.clear();
    if (texto.isEmpty) {
      await widget.controller.sendKey(const <int>[0x0D]);
      return;
    }
    await widget.controller.type('$texto\r');
  }

  @override
  Widget build(final BuildContext context) {
    final estado = widget.controller.state;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: widget.fontSize,
      height: 1.30,
      color: ChronoxColors.textPrimary,
    );

    return Container(
      color: const Color(0xFF0B0D13),
      child: Column(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              // Tocar la pantalla devuelve el foco al campo oculto: sin teclado
              // la terminal no sirve de nada, y perder el foco es fácil.
              onTap: () => _foco.requestFocus(),
              child: estado.status == TerminalStatus.failed
                  ? _Aviso(
                      mensaje: estado.message,
                      onReintentar: widget.controller.open,
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            for (var i = 0; i < estado.lines.length; i++)
                              _Linea(
                                linea: estado.lines[i],
                                esCursor: i == estado.cursorRow,
                                columnaCursor: estado.cursorCol,
                                estilo: mono,
                              ),
                            if (estado.status == TerminalStatus.exited)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Text(
                                  estado.message,
                                  style: const TextStyle(
                                    color: ChronoxColors.warning,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          _BarraTeclas(
            controller: widget.controller,
            habilitada: estado.canType,
          ),
          _BarraEntrada(
            controller: _entrada,
            focusNode: _foco,
            habilitada: estado.canType,
            onEnviar: _enviar,
          ),
        ],
      ),
    );
  }
}

/// Una línea con su estilo por celda, y el cursor si le corresponde.
class _Linea extends StatelessWidget {
  const _Linea({
    required this.linea,
    required this.esCursor,
    required this.columnaCursor,
    required this.estilo,
  });

  final TerminalLine linea;
  final bool esCursor;
  final int columnaCursor;
  final TextStyle estilo;

  @override
  Widget build(final Widget context) {
    final spans = <InlineSpan>[];
    var indice = 0;

    void agregar(final String texto, final TextStyle estilo, {final bool cursor = false}) {
      if (texto.isEmpty) return;
      spans.add(
        TextSpan(
          text: texto,
          style: cursor
              ? estilo.copyWith(
                  backgroundColor: ChronoxColors.primary,
                  color: ChronoxColors.background,
                )
              : estilo,
        ),
      );
    }

    for (final celda in linea.cells) {
      if (esCursor && indice == columnaCursor) {
        agregar(celda.char, estilo, cursor: true);
      } else {
        agregar(
          celda.char,
          estilo.copyWith(
            color: _color(celda.style.foreground, porDefecto: ChronoxColors.textPrimary),
            backgroundColor: celda.style.background == null
                ? null
                : _color(celda.style.background, porDefecto: Colors.transparent),
            fontWeight: celda.style.bold ? FontWeight.w700 : FontWeight.w400,
          ),
        );
      }
      indice++;
    }

    // Cursor al final de la línea (el caso normal: el prompt vacío).
    if (esCursor && columnaCursor >= linea.cells.length) {
      agregar(' ', estilo, cursor: true);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: RichText(
        softWrap: true,
        text: TextSpan(style: estilo, children: spans),
      ),
    );
  }
}

/// Aviso a pantalla completa cuando no hay terminal.
class _Aviso extends StatelessWidget {
  const _Aviso({required this.mensaje, required this.onReintentar});

  final String mensaje;
  final Future<void> Function() onReintentar;

  @override
  Widget build(final Widget context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.terminal_rounded,
              size: 30,
              color: ChronoxColors.textMuted,
            ),
            const SizedBox(height: 14),
            Text(
              mensaje,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ChronoxColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onReintentar,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Teclas que un teclado de móvil no tiene.
class _BarraTeclas extends StatelessWidget {
  const _BarraTeclas({required this.controller, required this.habilitada});

  final TerminalController controller;
  final bool habilitada;

  @override
  Widget build(final Widget context) {
    final teclas = <({String etiqueta, List<int> codigo})>[
      (etiqueta: '↑', codigo: ControlKeys.arrowUp),
      (etiqueta: '↓', codigo: ControlKeys.arrowDown),
      (etiqueta: 'Tab', codigo: const <int>[ControlKeys.tab]),
      (etiqueta: 'Ctrl+C', codigo: const <int>[ControlKeys.ctrlC]),
      (etiqueta: 'Ctrl+D', codigo: const <int>[ControlKeys.ctrlD]),
      (etiqueta: 'Ctrl+L', codigo: const <int>[ControlKeys.ctrlL]),
    ];

    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: ChronoxColors.backgroundElevated,
        border: Border(top: BorderSide(color: ChronoxColors.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        children: <Widget>[
          for (final tecla in teclas)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Tecla(
                etiqueta: tecla.etiqueta,
                onTap: habilitada
                    ? () => controller.sendKey(tecla.codigo)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _Tecla extends StatelessWidget {
  const _Tecla({required this.etiqueta, this.onTap});

  final String etiqueta;
  final VoidCallback? onTap;

  @override
  Widget build(final Widget context) {
    return Material(
      color: onTap == null
          ? ChronoxColors.surface
          : ChronoxColors.surface.withOpacity(0.9),
      borderRadius: BorderRadius.circular(ChronoxRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ChronoxRadius.sm),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          constraints: const BoxConstraints(minWidth: 42),
          child: Text(
            etiqueta,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: onTap == null
                  ? ChronoxColors.textMuted
                  : ChronoxColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Campo de entrada.
///
/// Enviar por línea y no carácter a carácter tiene una consecuencia que hay que
/// aceptar: no se ve lo que se escribe dentro de la pantalla del terminal hasta
/// que se envía, porque el eco lo produce el invitado. A cambio, la entrada
/// funciona con el teclado del sistema, con dictado y con autocorrección, que es
/// lo que de verdad se usa en un móvil.
class _BarraEntrada extends StatelessWidget {
  const _BarraEntrada({
    required this.controller,
    required this.focusNode,
    required this.habilitada,
    required this.onEnviar,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool habilitada;
  final Future<void> Function(String) onEnviar;

  @override
  Widget build(final Widget context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: const BoxDecoration(
          color: ChronoxColors.backgroundElevated,
          border: Border(top: BorderSide(color: ChronoxColors.border)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: habilitada,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.send,
                onSubmitted: onEnviar,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: ChronoxColors.textPrimary,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: habilitada ? 'Escribe un comando' : 'Sesión cerrada',
                  hintStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: ChronoxColors.textMuted,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                    borderSide: const BorderSide(color: ChronoxColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                    borderSide: const BorderSide(color: ChronoxColors.border),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              onPressed: habilitada ? () => onEnviar(controller.text) : null,
              icon: const Icon(Icons.keyboard_return_rounded),
              color: ChronoxColors.primary,
              tooltip: 'Ejecutar',
            ),
          ],
        ),
      ),
    );
  }
}
