import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/runtime/local_runtime.dart';
import '../../domain/agent/approval_policy.dart';
import '../../domain/modes/work_modes.dart';
import '../../domain/plugins/plugin_api.dart';
import '../../platform/android_permissions.dart';
import '../chat/approval_sheet.dart';
import '../state/app_state.dart';
import '../widgets/chronox_widgets.dart';
import 'diagnostics_screen.dart';

/// Ajustes: proveedor de modelo, modo de trabajo, permisos y estado del runtime.
///
/// El orden no es casual: primero lo que hace falta para que el agente funcione
/// (clave, modelo), después cómo trabaja (modo, permisos) y al final el estado del
/// sistema, que solo se consulta cuando algo va mal.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(final BuildContext context, final WidgetRef ref) {
    final settings = ref.watch(providerSettingsProvider);
    final mode = ref.watch(activeModeProvider);
    final level = ref.watch(approvalLevelProvider);
    final session = ref.watch(sessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 32),
        children: <Widget>[
          const SectionLabel('Modelo'),
          GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: <Widget>[
                SettingsRow(
                  icon: Icons.key_outlined,
                  title: 'Clave de API',
                  subtitle: settings.apiKey.isEmpty
                      ? 'Sin configurar: el agente no podrá pensar'
                      : 'Configurada (${_masked(settings.apiKey)})',
                  accent: settings.apiKey.isEmpty
                      ? ChronoxColors.warning
                      : ChronoxColors.success,
                  onTap: () => _editApiKey(context, ref, settings),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: ChronoxColors.textMuted,
                  ),
                ),
                const Divider(height: 1, color: ChronoxColors.border),
                SettingsRow(
                  icon: Icons.dns_outlined,
                  title: 'Servidor',
                  subtitle: settings.baseUrl,
                  onTap: () => _editBaseUrl(context, ref, settings),
                ),
                const Divider(height: 1, color: ChronoxColors.border),
                SettingsRow(
                  icon: Icons.memory_rounded,
                  title: 'Modelo',
                  subtitle: settings.model,
                  accent: ChronoxColors.accent,
                  onTap: () => _editModel(context, ref, settings),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              'Compatible con DeepSeek, OpenRouter, Groq, Together, vLLM, '
              'Ollama y LM Studio: basta con cambiar el servidor y el modelo.',
              style: TextStyle(
                color: ChronoxColors.textMuted.withOpacity(0.9),
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
          const SectionLabel('Modo de trabajo'),
          GlassPanel(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: <Widget>[
                for (final m in WorkModes.all) ...<Widget>[
                  _ModeOption(
                    mode: m,
                    selected: m.id == mode.id,
                    onTap: () async {
                      ref.read(activeModeProvider.notifier).state = m;
                      if (session != null) {
                        await _restartForMode(context, ref, m);
                      }
                    },
                  ),
                  if (m.id != WorkModes.all.last.id)
                    const Divider(height: 1, color: ChronoxColors.border),
                ],
              ],
            ),
          ),
          const SectionLabel('Permisos'),
          GlassPanel(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: <Widget>[
                for (final l in ApprovalLevel.values) ...<Widget>[
                  _LevelOption(
                    level: l,
                    selected: l == level,
                    onTap: () {
                      ref.read(approvalLevelProvider.notifier).state = l;
                      session?.policy.level = l;
                    },
                  ),
                  if (l != ApprovalLevel.values.last)
                    const Divider(height: 1, color: ChronoxColors.border),
                ],
              ],
            ),
          ),
          const SectionLabel('Sesión'),
          GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: <Widget>[
                SettingsRow(
                  icon: Icons.timeline_rounded,
                  title: 'Estadísticas',
                  subtitle: session == null
                      ? 'Sin sesión activa'
                      : _statsSummary(session),
                  accent: ChronoxColors.accent,
                ),
                const Divider(height: 1, color: ChronoxColors.border),
                SettingsRow(
                  icon: Icons.restart_alt_rounded,
                  title: 'Cerrar y abrir sesión nueva',
                  subtitle:
                      'El historial anterior queda guardado en su fichero de '
                      'sesión.',
                  accent: ChronoxColors.warning,
                  onTap: () async {
                    await session?.dispose();
                    await const AndroidPermissions().stopTerminalService();
                    ref.read(sessionProvider.notifier).state = null;
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Sesión cerrada. Abre una nueva.'),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SectionLabel('Compatibilidad'),
          GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: SettingsRow(
              icon: Icons.health_and_safety_outlined,
              title: 'Diagnóstico del dispositivo',
              subtitle:
                  'Comprueba si este Android permite ejecutar el contenedor, y '
                  'por qué no.',
              accent: ChronoxColors.success,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (final context) => const DiagnosticsScreen(),
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: ChronoxColors.textMuted,
              ),
            ),
          ),
          const SectionLabel('Acerca de'),
          GlassPanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: <Color>[
                            ChronoxColors.primary,
                            ChronoxColors.accent,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                      ),
                      child: const Icon(
                        Icons.bolt_rounded,
                        size: 19,
                        color: ChronoxColors.background,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Chronox AI',
                          style: TextStyle(
                            color: ChronoxColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Versión 0.1.0 (desarrollo)',
                          style: TextStyle(
                            color: ChronoxColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text(
                  'Agente de codificación con Linux propio en el dispositivo. '
                  'Nada de lo que hagas sale del teléfono salvo las peticiones '
                  'al proveedor de modelo que configures.',
                  style: TextStyle(
                    color: ChronoxColors.textSecondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _masked(final String key) {
    if (key.length <= 8) return '••••';
    return '${key.substring(0, 4)}…${key.substring(key.length - 4)}';
  }

  static String _statsSummary(final SessionRuntime session) {
    final stats = session.log.stats();
    return '${stats.turns} turnos · ${stats.toolCalls} herramientas · '
        '${stats.inputTokens + stats.outputTokens} tokens';
  }

  Future<void> _restartForMode(
    final BuildContext context,
    final WidgetRef ref,
    final PluginMode mode,
  ) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    await session.dispose();
    await const AndroidPermissions().stopTerminalService();
    ref.read(sessionProvider.notifier).state = null;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Modo "${session.mode.name}" cerrado. Abre una sesión nueva para '
          'trabajar con otro conjunto de plugins.',
        ),
      ),
    );
  }

  Future<void> _editApiKey(
    final BuildContext context,
    final WidgetRef ref,
    final ProviderSettings settings,
  ) async {
    final value = await _prompt(
      context,
      title: 'Clave de API',
      hint: 'sk-…',
      initial: settings.apiKey,
      helper:
          'Se envía solo al servidor que configures. No se escribe en el log de '
          'la sesión.',
      obscure: true,
    );
    if (value == null) return;
    ref.read(providerSettingsProvider.notifier).state =
        settings.copyWith(apiKey: value.trim());
  }

  Future<void> _editBaseUrl(
    final BuildContext context,
    final WidgetRef ref,
    final ProviderSettings settings,
  ) async {
    final value = await _prompt(
      context,
      title: 'Servidor',
      hint: 'https://api.deepseek.com/v1',
      initial: settings.baseUrl,
      helper: 'Se acepta la URL con o sin /v1.',
    );
    if (value == null || value.trim().isEmpty) return;
    ref.read(providerSettingsProvider.notifier).state =
        settings.copyWith(baseUrl: value.trim());
  }

  Future<void> _editModel(
    final BuildContext context,
    final WidgetRef ref,
    final ProviderSettings settings,
  ) async {
    final value = await _prompt(
      context,
      title: 'Modelo',
      hint: 'deepseek-chat',
      initial: settings.model,
      helper: 'El nombre exacto que espera el servidor.',
    );
    if (value == null || value.trim().isEmpty) return;
    ref.read(providerSettingsProvider.notifier).state =
        settings.copyWith(model: value.trim());
  }

  static Future<String?> _prompt(
    final BuildContext context, {
    required final String title,
    required final String hint,
    required final String initial,
    final String? helper,
    final bool obscure = false,
  }) {
    final controller = TextEditingController(text: initial);

    return showDialog<String>(
      context: context,
      builder: (final context) => AlertDialog(
        backgroundColor: ChronoxColors.backgroundElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ChronoxRadius.lg),
          side: const BorderSide(color: ChronoxColors.borderGlow),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: ChronoxColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: obscure,
              style: const TextStyle(
                color: ChronoxColors.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: ChronoxColors.textMuted),
                filled: true,
                fillColor: ChronoxColors.surface,
                border: const OutlineInputBorder(
                  borderRadius: ChronoxRadius.card,
                  borderSide: BorderSide(color: ChronoxColors.border),
                ),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: ChronoxRadius.card,
                  borderSide: BorderSide(color: ChronoxColors.border),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: ChronoxRadius.card,
                  borderSide: BorderSide(color: ChronoxColors.primary),
                ),
              ),
            ),
            if (helper != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                helper,
                style: const TextStyle(
                  color: ChronoxColors.textMuted,
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: ChronoxColors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final PluginMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(final BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: ChronoxRadius.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: <Widget>[
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? ChronoxColors.primary
                      : ChronoxColors.borderGlow,
                  width: selected ? 5 : 1.5,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    mode.name,
                    style: TextStyle(
                      color: selected
                          ? ChronoxColors.textPrimary
                          : ChronoxColors.textSecondary,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mode.description,
                    style: const TextStyle(
                      color: ChronoxColors.textMuted,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LevelOption extends StatelessWidget {
  const _LevelOption({
    required this.level,
    required this.selected,
    required this.onTap,
  });

  final ApprovalLevel level;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(final BuildContext context) {
    final color = switch (level) {
      ApprovalLevel.readOnly => ChronoxColors.success,
      ApprovalLevel.guarded => ChronoxColors.primary,
      ApprovalLevel.yolo => ChronoxColors.danger,
    };

    return InkWell(
      onTap: onTap,
      borderRadius: ChronoxRadius.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: selected ? color : ChronoxColors.borderGlow,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    level.label,
                    style: TextStyle(
                      color: selected
                          ? ChronoxColors.textPrimary
                          : ChronoxColors.textSecondary,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    level.description,
                    style: const TextStyle(
                      color: ChronoxColors.textMuted,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Diálogo para abrir una sesión nueva.
///
/// Es el punto donde el usuario decide con qué proveedor, modo y permisos va a
/// trabajar. Se pide todo junto porque cambiar cualquiera de los tres obliga a
/// reconstruir la sesión.
Future<void> showNewSessionDialog(
  final BuildContext context,
  final WidgetRef ref,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (final context) => const _NewSessionDialog(),
  );
}

class _NewSessionDialog extends ConsumerStatefulWidget {
  const _NewSessionDialog();

  @override
  ConsumerState<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<_NewSessionDialog> {
  bool _starting = false;
  String? _error;

  Future<void> _start() async {
    final settings = ref.read(providerSettingsProvider);
    if (!settings.isConfigured) {
      setState(() {
        _error =
            'Falta la clave de API o el modelo. Configúralos en Ajustes antes '
            'de abrir la sesión.';
      });
      return;
    }

    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      final sessionsDir = await ref.read(appSupportDirProvider.future);
      final mode = ref.read(activeModeProvider);
      final level = ref.read(approvalLevelProvider);

      final runtime = await ref.read(localRuntimeProvider.future);
      final status = await runtime.status();

      // Sin runtime se abre igualmente la sesión: el agente puede leer y
      // escribir en el workspace y le explica al modelo, en cada intento de
      // comando, qué falta. Bloquear aquí dejaría la app inutilizable hasta
      // terminar el instalador.
      final session = await startSession(
        SessionBootstrap(
          provider: clientFromSettings(settings),
          shell: status.isReady
              ? ProotShellSeam(runtime)
              : UnavailableShellSeam(status),
          fileSystem: WorkspaceFileSystemSeam(
            hostWorkspace: runtime.hostWorkspace,
          ),
          workspaceDir: Directory(runtime.hostWorkspace),
        ),
        mode: mode,
        approvalLevel: level,
        sessionsDir: sessionsDir,
      );

      // La UI responde a las peticiones de permiso con la hoja de aprobación.
      session.loop.approvalHandler = (final request) => showApprovalSheet(
            context,
            request: request,
            isHighRisk: ApprovalPolicy.isHighRisk(request.toolName),
          );

      // El servicio en primer plano es lo que impide que Android congele el
      // proceso (y mate proot) en cuanto la app pasa a segundo plano. Se arranca
      // desde aquí, con la actividad visible, porque desde API 31 no se puede
      // iniciar un servicio en primer plano en segundo plano.
      const permissions = AndroidPermissions();
      final notificationsGranted = await permissions.requestNotifications();
      final serviceStarted = await permissions.startTerminalService(
        title: 'Chronox: sesión ${mode.name}',
      );

      ref.read(sessionProvider.notifier).state = session;
      ref.read(agentViewProvider.notifier).sync();
      if (!mounted) return;
      Navigator.of(context).pop();
      final degraded = !status.isReady || !serviceStarted;
      if (degraded) {
        final message = !status.isReady
            ? 'Sesión abierta sin runtime Linux: ${status.title}. Los comandos '
                'todavía no se pueden ejecutar.'
            : notificationsGranted
                ? 'No se pudo mantener la sesión en segundo plano: Android puede '
                    'detener los comandos largos al cambiar de app.'
                : 'Sin permiso de notificaciones, el sistema puede detener los '
                    'comandos largos al cambiar de app.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(message), duration: const Duration(seconds: 6)),
        );
      }
    } catch (error) {
      setState(() {
        _starting = false;
        _error = 'No se pudo abrir la sesión: $error';
      });
    }
  }

  @override
  Widget build(final BuildContext context) {
    final settings = ref.watch(providerSettingsProvider);
    final mode = ref.watch(activeModeProvider);
    final level = ref.watch(approvalLevelProvider);
    final runtimeStatus = ref.watch(localRuntimeStatusProvider);

    return AlertDialog(
      backgroundColor: ChronoxColors.backgroundElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ChronoxRadius.lg),
        side: const BorderSide(color: ChronoxColors.borderGlow),
      ),
      title: const Text(
        'Nueva sesión',
        style: TextStyle(
          color: ChronoxColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SummaryLine(label: 'Modelo', value: settings.model),
          _SummaryLine(label: 'Servidor', value: settings.baseUrl),
          _SummaryLine(label: 'Modo', value: mode.name),
          _SummaryLine(label: 'Permisos', value: level.label),
          const SizedBox(height: 12),
          runtimeStatus.when(
            data: (final status) => Row(
              children: <Widget>[
                Icon(
                  status.isReady
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  size: 15,
                  color: status.isReady
                      ? ChronoxColors.success
                      : ChronoxColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.isReady ? 'Runtime Linux listo' : status.message,
                    style: TextStyle(
                      color: status.isReady
                          ? ChronoxColors.success
                          : ChronoxColors.textMuted,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            loading: () => const Text(
              'Comprobando el runtime…',
              style: TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 11.5,
              ),
            ),
            error: (final error, final _) => Text(
              '$error',
              style: const TextStyle(
                color: ChronoxColors.danger,
                fontSize: 11.5,
              ),
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: ChronoxColors.danger,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _starting ? null : () => Navigator.of(context).pop(),
          child: const Text(
            'Cancelar',
            style: TextStyle(color: ChronoxColors.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: _starting ? null : _start,
          child: _starting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Abrir'),
        ),
      ],
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: const TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: ChronoxColors.textSecondary,
                fontSize: 12,
                fontFamily: ChronoxTheme.monoFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
