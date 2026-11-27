import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/terminal/runtime_compat.dart';
import '../../platform/android_permissions.dart';
import '../state/app_state.dart';
import '../widgets/chronox_widgets.dart';

/// Diagnóstico de compatibilidad con el dispositivo real.
///
/// Existe por una razón concreta: cuando el contenedor no arranca, el usuario no
/// tiene forma de saber si es su Android, su ROM, el ABI o los binarios. Aquí se
/// muestra el dato medido (no una suposición) y qué hacer al respecto.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  final AndroidPermissions _permissions = const AndroidPermissions();
  bool? _notificationsGranted;
  bool? _batteryUnrestricted;

  @override
  void initState() {
    super.initState();
    _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final unrestricted = await _permissions.isBatteryUnrestricted();
    if (!mounted) return;
    setState(() {
      _batteryUnrestricted = unrestricted;
      // No se consulta el estado de las notificaciones: pedirlo dos veces sin
      // interacción del usuario es invasivo. Se refleja solo cuando se pide.
    });
  }

  @override
  Widget build(final BuildContext context) {
    final runtimeAsync = ref.watch(localRuntimeProvider);
    final statusAsync = ref.watch(localRuntimeStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico'),
        actions: <Widget>[
          IconButton(
            onPressed: () {
              ref.invalidate(localRuntimeStatusProvider);
              _refreshPermissions();
            },
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Volver a comprobar',
          ),
        ],
      ),
      body: runtimeAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: ChronoxColors.primary),
        ),
        error: (final error, final _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudo leer el dispositivo',
          message: '$error',
        ),
        data: (final runtime) => FutureBuilder(
          future: runtime.facts(),
          builder: (final context, final snapshot) {
            final facts = snapshot.data;
            if (facts == null) {
              return const Center(
                child: CircularProgressIndicator(color: ChronoxColors.primary),
              );
            }

            final issues = runtime.compatIssues;
            final blocking = issues.where((final i) => i.isBlocking).toList();
            final warnings = issues
                .where((final i) => i.severity == CompatSeverity.warning)
                .toList();
            final notes = issues
                .where((final i) => i.severity == CompatSeverity.note)
                .toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
              children: <Widget>[
                _VerdictCard(
                  ok: blocking.isEmpty,
                  summary: RuntimeCompatibility.summary(facts),
                  title: blocking.isEmpty
                      ? 'Este dispositivo puede ejecutar el contenedor'
                      : 'Este dispositivo no puede ejecutar el contenedor',
                ),
                if (statusAsync.valueOrNull != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10, left: 2, right: 2),
                    child: Text(
                      statusAsync.value!.isReady
                          ? 'Runtime listo para usar.'
                          : 'Runtime: ${statusAsync.value!.title}.',
                      style: const TextStyle(
                        color: ChronoxColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (blocking.isNotEmpty) ...<Widget>[
                  const SectionLabel('Bloqueantes'),
                  for (final issue in blocking) _IssueCard(issue: issue),
                ],
                if (warnings.isNotEmpty) ...<Widget>[
                  const SectionLabel('Avisos'),
                  for (final issue in warnings) _IssueCard(issue: issue),
                ],
                if (notes.isNotEmpty) ...<Widget>[
                  const SectionLabel('Notas'),
                  for (final issue in notes) _IssueCard(issue: issue),
                ],
                const SectionLabel('Permisos del sistema'),
                GlassPanel(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    children: <Widget>[
                      SettingsRow(
                        icon: _notificationsGranted == false
                            ? Icons.notifications_off_outlined
                            : Icons.notifications_active_outlined,
                        title: 'Notificaciones',
                        subtitle: _notificationsGranted == null
                            ? 'Necesarias para que el servicio de comandos sea '
                                'visible en Android 13+'
                            : _notificationsGranted!
                                ? 'Concedidas'
                                : 'Denegadas: el servicio funcionará sin avisarte',
                        accent: _notificationsGranted == false
                            ? ChronoxColors.warning
                            : ChronoxColors.primary,
                        onTap: () async {
                          final granted =
                              await _permissions.requestNotifications();
                          if (mounted) {
                            setState(() => _notificationsGranted = granted);
                          }
                        },
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: ChronoxColors.textMuted,
                        ),
                      ),
                      const Divider(height: 1, color: ChronoxColors.border),
                      SettingsRow(
                        icon: Icons.battery_saver_outlined,
                        title: 'Sin restricciones de batería',
                        subtitle: _batteryUnrestricted == null
                            ? 'Comprobando…'
                            : _batteryUnrestricted!
                                ? 'La app puede trabajar con la pantalla apagada'
                                : 'El sistema puede detener los comandos largos',
                        accent: _batteryUnrestricted == false
                            ? ChronoxColors.warning
                            : ChronoxColors.success,
                        onTap: () async {
                          await _permissions.requestBatteryUnrestricted();
                          await _refreshPermissions();
                        },
                        trailing: _batteryUnrestricted == true
                            ? const Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                                color: ChronoxColors.success,
                              )
                            : const Icon(
                                Icons.chevron_right_rounded,
                                color: ChronoxColors.textMuted,
                              ),
                      ),
                    ],
                  ),
                ),
                const SectionLabel('Datos del dispositivo'),
                GlassPanel(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    children: <Widget>[
                      _FactRow('Fabricante', facts.manufacturer),
                      _FactRow('Modelo', facts.model),
                      _FactRow(
                        'Android',
                        '${facts.release} (API ${facts.sdkInt})',
                      ),
                      _FactRow('Arquitectura', facts.abi),
                      _FactRow(
                        'Tamaño de página',
                        '${facts.pageSize ~/ 1024} KB',
                      ),
                      _FactRow('targetSdk', '${facts.targetSdk}'),
                      _FactRow('Dominio SELinux', facts.expectedDomain),
                      _FactRow(
                        'Ejecutar desde la app',
                        facts.canExecuteFromData == null
                            ? 'no comprobado'
                            : facts.canExecuteFromData!
                                ? 'permitido'
                                : 'bloqueado',
                      ),
                      _FactRow(
                          'proot', facts.nativeLibraryDir ?? 'no extraído'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                  child: Text(
                    'El dominio SELinux decide si Android permite ejecutar proot. '
                    'Se lee del proceso en tiempo de ejecución, no se deduce de la '
                    'versión.',
                    style: TextStyle(
                      color: ChronoxColors.textMuted.withOpacity(0.9),
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({
    required this.ok,
    required this.summary,
    required this.title,
  });

  final bool ok;
  final String summary;
  final String title;

  @override
  Widget build(final BuildContext context) {
    final color = ok ? ChronoxColors.success : ChronoxColors.danger;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: ChronoxRadius.cardLarge,
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            ok ? Icons.verified_rounded : Icons.report_problem_rounded,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: ChronoxColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  summary,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontFamily: ChronoxTheme.monoFamily,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({required this.issue});

  final CompatIssue issue;

  @override
  Widget build(final BuildContext context) {
    final (color, icon) = switch (issue.severity) {
      CompatSeverity.blocking => (ChronoxColors.danger, Icons.block_rounded),
      CompatSeverity.warning => (
          ChronoxColors.warning,
          Icons.warning_amber_rounded,
        ),
      CompatSeverity.note => (ChronoxColors.accent, Icons.info_outline_rounded),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: ChronoxColors.surface,
          borderRadius: ChronoxRadius.card,
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    issue.title,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              issue.detail,
              style: const TextStyle(
                color: ChronoxColors.textSecondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            if (issue.advice.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ChronoxColors.backgroundElevated,
                  borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.lightbulb_outline_rounded,
                      size: 14,
                      color: ChronoxColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        issue.advice,
                        style: const TextStyle(
                          color: ChronoxColors.textSecondary,
                          fontSize: 11.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 148,
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
