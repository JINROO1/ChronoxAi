import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/agent/approval_policy.dart';
import '../../domain/modes/work_modes.dart';
import '../../domain/plugins/plugin_api.dart';
import '../../platform/scheduler_channel.dart';
import '../../platform/voice_channel.dart';
import '../settings/settings_screen.dart';
import '../state/app_state.dart';
import '../widgets/chronox_widgets.dart';
import 'approval_sheet.dart';
import 'message_bubble.dart';
import 'plan_sheet.dart';
import 'sessions_browser.dart';
import 'workspace_projects_menu.dart';

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

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  int _lastKnownLength = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadScheduledPrompt();
  }

  @override
  void didChangeAppLifecycleState(final AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadScheduledPrompt();
  }

  Future<void> _loadScheduledPrompt() async {
    try {
      final prompt = await const SchedulerChannel().takeLaunchPrompt();
      if (prompt != null && prompt.isNotEmpty && mounted) {
        _input.text = prompt;
      }
    } on PlatformException {
      // Desktop/test environment has no Android scheduler bridge.
    } on MissingPluginException {
      // No-op outside Android.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

    // Los diálogos de nueva sesión se cierran antes de enviar el primer turno;
    // sus BuildContext quedan desmontados. Enlaza las confirmaciones al contexto
    // vivo de ChatScreen justo antes de iniciar el loop.
    session.loop.approvalHandler = (final request) => showApprovalSheet(
          context,
          request: request,
          isHighRisk: ApprovalPolicy.isHighRisk(request.toolName),
        );
    session.loop.planHandler = (final request) => showPlanSheet(
          context,
          plan: request.plan,
        );

    final reason = await session.loop.runTurn(text);
    view.markFinished(reason);
    _lastKnownLength = -1; // fuerza a repintar la transcripción completa
    if (mounted) setState(() {});
  }

  Future<void> _cancel() async {
    final session = ref.read(sessionProvider);
    await session?.loop.cancel();
  }

  Future<void> _quickSettings() async {
    final session = ref.read(sessionProvider);
    PluginMode mode = ref.read(activeModeProvider);
    ApprovalLevel level =
        session?.policy.level ?? ref.read(approvalLevelProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Controles de sesión'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButtonFormField<PluginMode>(
                value: mode,
                decoration: const InputDecoration(labelText: 'Modo'),
                items: WorkModes.all
                    .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => mode = value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ApprovalLevel>(
                value: level,
                decoration: const InputDecoration(labelText: 'Confirmación'),
                items: ApprovalLevel.values
                    .map(
                        (v) => DropdownMenuItem(value: v, child: Text(v.label)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => level = value);
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                ref.read(approvalLevelProvider.notifier).state = level;
                if (session != null) session.policy.level = level;
                ref.read(activeModeProvider.notifier).state = mode;
                Navigator.pop(dialogContext);
                if (session != null && session.mode.id != mode.id && mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(
                        content: Text(
                      'Modo actualizado. Abre una nueva sesión para cargar sus herramientas.',
                    )),
                  );
                }
                if (mounted) setState(() {});
              },
              child: const Text('Aplicar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _dictate() async {
    try {
      final phrase = await const VoiceChannel().recognize();
      if (phrase != null && phrase.trim().isNotEmpty && mounted) {
        final current = _input.text.trim();
        _input.text =
            current.isEmpty ? phrase.trim() : '$current ${phrase.trim()}';
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(error.message ?? 'No se pudo reconocer la voz.')),
        );
      }
    } on MissingPluginException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('La entrada de voz solo está disponible en Android.')),
        );
      }
    }
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
            action: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'projects')
                      showWorkspaceProjectsMenu(context, ref);
                    if (action == 'new') showNewSessionDialog(context, ref);
                  },
                  itemBuilder: (_) => const <PopupMenuEntry<String>>[
                    PopupMenuItem(
                        value: 'projects',
                        child: Text('Proyectos del Workspace')),
                    PopupMenuItem(value: 'new', child: Text('Nueva sesión')),
                  ],
                  child: FilledButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Proyectos'),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => showNewSessionDialog(context, ref),
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('Abrir una sesión'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => showSessionsBrowser(context),
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Chats guardados'),
                ),
              ],
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
    final reasoning = ref.watch(liveReasoningProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _SessionHeader(
              session: session,
              onOpenTerminal: () => openTerminalSheet(context),
              onOpenSessions: () => showSessionsBrowser(context),
              onNewSession: () => showNewSessionDialog(context, ref),
              onQuickSettings: _quickSettings,
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
            if (reasoning.isNotEmpty) _LiveReasoning(text: reasoning),
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
              onDictate: _dictate,
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveReasoning extends StatefulWidget {
  const _LiveReasoning({required this.text});
  final String text;

  @override
  State<_LiveReasoning> createState() => _LiveReasoningState();
}

class _LiveReasoningState extends State<_LiveReasoning> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Container(
          decoration: BoxDecoration(
            color: ChronoxColors.surface,
            border: Border.all(color: ChronoxColors.border),
            borderRadius: ChronoxRadius.card,
          ),
          child: Column(children: <Widget>[
            ListTile(
              dense: true,
              leading: const Icon(Icons.psychology_alt_outlined, size: 18),
              title: const Text('Razonamiento del modelo'),
              trailing: IconButton(
                tooltip: _expanded ? 'Plegar' : 'Expandir',
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 150),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: SelectableText(widget.text,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                ),
              ),
          ]),
        ),
      );
}

/// Cabecera: identidad de la app, modo activo y consumo de la sesión.
class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.session,
    required this.onOpenTerminal,
    required this.onOpenSessions,
    required this.onNewSession,
    required this.onQuickSettings,
  });

  final SessionRuntime session;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenSessions;
  final VoidCallback onNewSession;
  final VoidCallback onQuickSettings;

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
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
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
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Acciones del chat',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) {
              switch (action) {
                case 'settings':
                  onQuickSettings();
                case 'new':
                  onNewSession();
                case 'history':
                  onOpenSessions();
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem(
                  value: 'settings', child: Text('Modo y confirmación')),
              PopupMenuItem(value: 'new', child: Text('Nueva sesión')),
              PopupMenuItem(
                  value: 'history', child: Text('Sesiones e historial')),
            ],
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
    required this.onDictate,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isRunning;
  final String activity;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onDictate;

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
              const SizedBox(width: 4),
              IconButton(
                onPressed: isRunning ? null : onDictate,
                tooltip: 'Dictar',
                icon: const Icon(Icons.mic_none_rounded),
              ),
              const SizedBox(width: 4),
              _SendButton(
                  isRunning: isRunning, onSend: onSend, onCancel: onCancel),
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
