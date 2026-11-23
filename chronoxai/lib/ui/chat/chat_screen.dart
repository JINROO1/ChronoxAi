import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/agent/approval_policy.dart';
import '../settings/settings_screen.dart';
import '../state/app_state.dart';
import '../widgets/chronox_widgets.dart';
import 'message_bubble.dart';

/// Pantalla de sesión: la conversación con el agente.
///
/// Aquí se junta todo lo demás: el motor escribe en el log, el log se convierte
/// en transcripción y la transcripción se pinta. La pantalla no guarda estado
/// propio de la conversación a propósito; solo el borrador del campo de texto.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  int _lastKnownLength = -1;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    // Se hace en el frame siguiente: si no, la lista aún no mide el mensaje
    // nuevo y el desplazamiento se queda corto.
    WidgetsBinding.instance.addPostFrameCallback((final _) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;

    final session = ref.read(sessionProvider);
    if (session == null) return;

    _input.clear();
    final view = ref.read(agentViewProvider.notifier);
    view.markRunning('Pensando…');

    final reason = await session.loop.runTurn(text);
    view.markFinished(reason);
    _lastKnownLength = -1; // fuerza a repintar la transcripción completa
    if (mounted) setState(() {});
  }

  Future<void> _cancel() async {
    final session = ref.read(sessionProvider);
    await session?.loop.cancel();
  }

  @override
  Widget build(final BuildContext context) {
    final session = ref.watch(sessionProvider);
    final view = ref.watch(agentViewProvider);

    if (session == null) {
      return Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.terminal,
            title: 'Sin sesión activa',
            message:
                'Abre una sesión para que el agente pueda leer, escribir y '
                'ejecutar comandos en el contenedor Linux.',
            action: FilledButton.icon(
              onPressed: () => showNewSessionDialog(context, ref),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Abrir sesión'),
            ),
          ),
        ),
      );
    }

    final history = session.log.events;
    if (history.length != _lastKnownLength) {
      _lastKnownLength = history.length;
      _scrollToBottom();
    }
    final entries = transcriptOf(history);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _SessionHeader(
              session: session,
              view: view,
              onOpenTerminal: () => openTerminalSheet(context),
            ),
            const Divider(height: 1, color: ChronoxColors.border),
            Expanded(
              child: entries.isEmpty
                  ? const EmptyState(
                      icon: Icons.auto_awesome,
                      title: 'Chronox está listo',
                      message:
                          'Pídele que lea el proyecto, ejecute tests o instale '
                          'lo que necesites. Verás cada comando antes de que se '
                          'ejecute.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
                      itemCount: entries.length,
                      itemBuilder: (final context, final i) =>
                          MessageBubble(entry: entries[i]),
                    ),
            ),
            if (view.error != null)
              _ErrorBanner(
                message: view.error!,
                onDismiss: () =>
                    ref.read(agentViewProvider.notifier).clearError(),
              ),
            _ComposerBar(
              controller: _input,
              focusNode: _inputFocus,
              isRunning: view.isRunning,
              activity: view.activity,
              onSend: _send,
              onCancel: _cancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// Cabecera: identidad de la app, modo activo y consumo de la sesión.
class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.session,
    required this.view,
    required this.onOpenTerminal,
  });

  final SessionRuntime session;
  final AgentViewState view;
  final VoidCallback onOpenTerminal;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: <Color>[ChronoxColors.primary, ChronoxColors.accent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(ChronoxRadius.sm),
            ),
            child: const Icon(
              Icons.bolt_rounded,
              size: 19,
              color: ChronoxColors.background,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  session.log.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ChronoxColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    StatusPill(
                      label: session.mode.name,
                      dense: true,
                      color: ChronoxColors.accent,
                      icon: Icons.layers_outlined,
                    ),
                    const SizedBox(width: 6),
                    StatusPill(
                      label: session.policy.level.label,
                      dense: true,
                      color: session.policy.level == ApprovalLevel.yolo
                          ? ChronoxColors.danger
                          : ChronoxColors.primary,
                      icon: Icons.shield_outlined,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (view.inputTokens + view.outputTokens > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '${((view.inputTokens + view.outputTokens) / 1000).toStringAsFixed(1)}k tok',
                style: const TextStyle(
                  color: ChronoxColors.textMuted,
                  fontSize: 11,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ),
          IconButton(
            onPressed: onOpenTerminal,
            icon: const Icon(Icons.terminal_rounded),
            color: ChronoxColors.textSecondary,
            tooltip: 'Terminal',
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: ChronoxColors.danger.withOpacity(0.10),
          borderRadius: ChronoxRadius.card,
          border: Border.all(color: ChronoxColors.danger.withOpacity(0.35)),
        ),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.error_outline_rounded,
              size: 17,
              color: ChronoxColors.danger,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: ChronoxColors.danger,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 16),
              color: ChronoxColors.danger,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

/// Campo de entrada y botón de envío/cancelación.
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.focusNode,
    required this.isRunning,
    required this.activity,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isRunning;
  final String activity;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(final BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + bottomInset),
      decoration: const BoxDecoration(
        color: ChronoxColors.backgroundElevated,
        border: Border(top: BorderSide(color: ChronoxColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (isRunning)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 4),
              child: Row(
                children: <Widget>[
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: ChronoxColors.primary,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      activity.isEmpty ? 'Trabajando…' : activity,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ChronoxColors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  decoration: BoxDecoration(
                    color: ChronoxColors.surface,
                    borderRadius: ChronoxRadius.cardLarge,
                    border: Border.all(color: ChronoxColors.border),
                  ),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                      color: ChronoxColors.textPrimary,
                      fontSize: 14.5,
                      height: 1.4,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Pide algo al agente…',
                      hintStyle: TextStyle(
                        color: ChronoxColors.textMuted,
                        fontSize: 14.5,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 13,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SendButton(isRunning: isRunning, onSend: onSend, onCancel: onCancel),
            ],
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.isRunning,
    required this.onSend,
    required this.onCancel,
  });

  final bool isRunning;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(final BuildContext context) {
    return Semantics(
      button: true,
      label: isRunning ? 'Detener' : 'Enviar',
      child: GestureDetector(
        onTap: isRunning ? onCancel : onSend,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: isRunning
                ? null
                : const LinearGradient(
                    colors: <Color>[
                      ChronoxColors.primary,
                      ChronoxColors.primaryDim,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            color: isRunning ? ChronoxColors.danger.withOpacity(0.16) : null,
            borderRadius: ChronoxRadius.cardLarge,
            border: isRunning
                ? Border.all(color: ChronoxColors.danger.withOpacity(0.5))
                : null,
            boxShadow: isRunning
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: ChronoxColors.primary.withOpacity(0.22),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Icon(
            isRunning ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            color: isRunning ? ChronoxColors.danger : ChronoxColors.background,
            size: 22,
          ),
        ),
      ),
    );
  }
}
