import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../state/app_state.dart';

/// Una entrada de la transcripción, con el estilo que le corresponde.
///
/// Los tres tipos se distinguen por **forma**, no solo por color: el mensaje del
/// usuario va alineado a la derecha con relleno, el del agente ocupa el ancho sin
/// fondo, y la herramienta se muestra como un bloque de código con su estado. Así
/// la conversación se sigue de un vistazo aunque no se distingan los colores.
class MessageBubble extends StatelessWidget {
  const MessageBubble({required this.entry, super.key});

  final TranscriptEntry entry;

  @override
  Widget build(final BuildContext context) {
    return switch (entry.kind) {
      TranscriptKind.user => _UserMessage(text: entry.text),
      TranscriptKind.assistant => _AssistantMessage(text: entry.text),
      TranscriptKind.tool => _ToolCallBlock(entry: entry),
      TranscriptKind.notice => _Notice(entry: entry),
    };
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.text});

  final String text;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, left: 36),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.fromLTRB(15, 11, 15, 12),
          decoration: BoxDecoration(
            color: ChronoxColors.primary.withOpacity(0.12),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(ChronoxRadius.md),
              topRight: Radius.circular(ChronoxRadius.md),
              bottomLeft: Radius.circular(ChronoxRadius.md),
              bottomRight: Radius.circular(5),
            ),
            border: Border.all(color: ChronoxColors.primary.withOpacity(0.28)),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(
              color: ChronoxColors.textPrimary,
              fontSize: 14.5,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.text});

  final String text;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 3,
            margin: const EdgeInsets.only(top: 3, bottom: 3, right: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: <Color>[ChronoxColors.primary, ChronoxColors.accent],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: SelectableText(
              text,
              style: const TextStyle(
                color: ChronoxColors.textPrimary,
                fontSize: 14.5,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bloque de una llamada a herramienta: quién, qué y qué devolvió.
class _ToolCallBlock extends StatefulWidget {
  const _ToolCallBlock({required this.entry});

  final TranscriptEntry entry;

  @override
  State<_ToolCallBlock> createState() => _ToolCallBlockState();
}

class _ToolCallBlockState extends State<_ToolCallBlock> {
  bool _expanded = false;

  static const Map<String, IconData> _icons = <String, IconData>{
    'read': Icons.description_outlined,
    'write': Icons.save_outlined,
    'edit': Icons.edit_outlined,
    'bash': Icons.terminal_rounded,
    'glob': Icons.search_rounded,
    'grep': Icons.filter_alt_outlined,
    'apply_patch': Icons.merge_rounded,
    'todo_write': Icons.checklist_rounded,
    'subagent': Icons.hub_outlined,
    'web_fetch': Icons.public_rounded,
    'run_code': Icons.code_rounded,
  };

  @override
  Widget build(final BuildContext context) {
    final entry = widget.entry;
    final accent = entry.isError
        ? ChronoxColors.danger
        : entry.isPending
            ? ChronoxColors.warning
            : ChronoxColors.accent;
    final icon = _icons[entry.title] ?? Icons.build_outlined;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 24),
      child: Container(
        decoration: BoxDecoration(
          color: ChronoxColors.codeBackground,
          borderRadius: ChronoxRadius.card,
          border: Border.all(color: accent.withOpacity(0.22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: ChronoxRadius.card,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 9, 10, 9),
                child: Row(
                  children: <Widget>[
                    Icon(icon, size: 14, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      entry.title ?? 'herramienta',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: ChronoxTheme.monoFamily,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (entry.isPending)
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: ChronoxColors.warning,
                        ),
                      ),
                    const Spacer(),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: ChronoxColors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            if (!_expanded && entry.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 0, 11, 9),
                child: Text(
                  entry.text.split('\n').first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ChronoxColors.textMuted,
                    fontSize: 11.5,
                    fontFamily: ChronoxTheme.monoFamily,
                  ),
                ),
              ),
            if (_expanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(11, 2, 11, 11),
                child: SelectableText(
                  entry.text,
                  style: TextStyle(
                    color: entry.isError
                        ? ChronoxColors.danger
                        : ChronoxColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.5,
                    fontFamily: ChronoxTheme.monoFamily,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider(color: ChronoxColors.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.compress_rounded,
                  size: 13,
                  color: ChronoxColors.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  entry.title ?? 'Aviso',
                  style: const TextStyle(
                    color: ChronoxColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Expanded(child: Divider(color: ChronoxColors.border)),
        ],
      ),
    );
  }
}

/// Hoja inferior con una terminal interactiva sobre el contenedor.
Future<void> openTerminalSheet(final BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (final context) => const _TerminalLauncher(),
    );

class _TerminalLauncher extends StatelessWidget {
  const _TerminalLauncher();

  @override
  Widget build(final BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (final context, final controller) => Container(
        decoration: const BoxDecoration(
          color: ChronoxColors.backgroundElevated,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(ChronoxRadius.lg),
          ),
          border: Border(
            top: BorderSide(color: ChronoxColors.borderGlow),
          ),
        ),
        child: Column(
          children: <Widget>[
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: ChronoxColors.borderGlow,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 10, 10),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.terminal_rounded,
                    size: 17,
                    color: ChronoxColors.primary,
                  ),
                  const SizedBox(width: 9),
                  const Text(
                    'Terminal',
                    style: TextStyle(
                      color: ChronoxColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 19),
                    color: ChronoxColors.textMuted,
                  ),
                ],
              ),
            ),
            const Expanded(
              child: _TerminalPlaceholder(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Marcador honesto: el emulador VT y el PTY viven en la capa de terminal, que
/// todavía no está conectada. Se deja explícito en lugar de mostrar una caja
/// negra que parece un fallo.
class _TerminalPlaceholder extends StatelessWidget {
  const _TerminalPlaceholder();

  @override
  Widget build(final BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.keyboard_alt_outlined,
              size: 30,
              color: ChronoxColors.textMuted,
            ),
            const SizedBox(height: 14),
            const Text(
              'La terminal interactiva aún no está conectada',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ChronoxColors.textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'El runtime de proot ya construye la orden de arranque; falta '
              'enganchar el PTY y el emulador de pantalla.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () {
                unawaited(
                  Clipboard.setData(
                    const ClipboardData(
                      text: 'apt update && apt install -y git',
                    ),
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Comando copiado')),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 15),
              label: const Text('Copiar comando de ejemplo'),
            ),
          ],
        ),
      ),
    );
  }
}
