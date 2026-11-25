import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../state/app_state.dart';
import '../terminal/multi_terminal_screen.dart';

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
    'list_dir': Icons.folder_open_outlined,
    'file_exists': Icons.fact_check_outlined,
    'git_status': Icons.account_tree_outlined,
    'git_diff': Icons.difference_outlined,
    'git_log': Icons.history_rounded,
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

/// Abre la consola interactiva completa, con pestañas para varios PTY.
Future<void> openTerminalSheet(final BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const MultiTerminalScreen(),
      ),
    );
