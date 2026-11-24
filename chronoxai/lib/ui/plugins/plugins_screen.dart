import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/plugins/plugin_api.dart';
import '../../domain/plugins/plugin_runtime.dart';
import '../state/app_state.dart';
import '../widgets/chronox_widgets.dart';
import 'plugin_surface_host.dart';

/// Pantalla de plugins: lo que hay montado, su estado y las pantallas que aportan.
///
/// Es la materialización de "todo es un plugin": aquí se ve qué está activo, qué
/// falló y por qué, y cualquier plugin con pantalla propia aparece en la lista sin
/// tocar esta pantalla.
class PluginsScreen extends ConsumerStatefulWidget {
  const PluginsScreen({super.key});

  @override
  ConsumerState<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends ConsumerState<PluginsScreen> {
  @override
  Widget build(final BuildContext context) {
    final session = ref.watch(sessionProvider);

    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Plugins')),
        body: const EmptyState(
          icon: Icons.extension_outlined,
          title: 'Sin sesión',
          message:
              'Abre una sesión para ver y activar plugins. Cada modo de trabajo '
              'monta un conjunto distinto.',
        ),
      );
    }

    final plugins = session.host.plugins;
    final surfaces = <({String pluginId, PluginSurface surface})>[
      for (final plugin in plugins)
        if (session.host.surfaceOf(plugin.manifest.id) != null)
          (
            pluginId: plugin.manifest.id,
            surface: session.host.surfaceOf(plugin.manifest.id)!,
          ),
    ];
    final warnings = <String>[
      for (final plugin in plugins)
        if (plugin.error != null) '${plugin.manifest.name}: ${plugin.error}',
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plugins'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: StatusPill(
                label:
                    '${session.host.mounted.length}/${plugins.length} activos',
                dense: true,
                color: session.host.mounted.length == plugins.length
                    ? ChronoxColors.success
                    : ChronoxColors.warning,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 32),
        children: <Widget>[
          if (warnings.isNotEmpty) ...<Widget>[
            const SectionLabel('Avisos'),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ChronoxColors.danger.withOpacity(0.08),
                    borderRadius: ChronoxRadius.card,
                    border: Border.all(
                      color: ChronoxColors.danger.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 16,
                        color: ChronoxColors.danger,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          warning,
                          style: const TextStyle(
                            color: ChronoxColors.danger,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (surfaces.isNotEmpty) ...<Widget>[
            const SectionLabel('Pantallas de plugins'),
            PluginSurfaceGrid(
              entries: surfaces,
              onOpen: (final pluginId) => openPluginSurface(
                context,
                pluginId: pluginId,
                surface: session.host.surfaceOf(pluginId)!,
              ),
            ),
          ],
          const SectionLabel('Plugin de la sesión'),
          for (final plugin in plugins)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PluginTile(
                plugin: plugin,
                onToggle: (final enabled) async {
                  final pluginId = plugin.manifest.id;
                  if (enabled) {
                    await session.host.mount(pluginId);
                  } else {
                    await session.host.unmount(pluginId);
                  }
                  await ref
                      .read(disabledPluginIdsProvider.notifier)
                      .setEnabled(pluginId, enabled);
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PluginTile extends StatelessWidget {
  const _PluginTile({required this.plugin, required this.onToggle});

  final LoadedPlugin plugin;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(final BuildContext context) {
    final manifest = plugin.manifest;
    final isMounted = plugin.isMounted;
    final hasError = plugin.state == PluginState.failed;

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      borderColor: hasError
          ? ChronoxColors.danger.withOpacity(0.4)
          : ChronoxColors.border,
      child: Row(
        children: <Widget>[
          _KindBadge(kind: manifest.kind),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  manifest.name,
                  style: const TextStyle(
                    color: ChronoxColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasError
                      ? (plugin.error ?? 'Error al montar')
                      : manifest.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasError
                        ? ChronoxColors.danger
                        : ChronoxColors.textMuted,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: isMounted,
            onChanged: hasError ? null : onToggle,
            activeColor: ChronoxColors.background,
            activeTrackColor: ChronoxColors.primary,
            inactiveThumbColor: ChronoxColors.textMuted,
            inactiveTrackColor: ChronoxColors.surfaceHigh,
          ),
        ],
      ),
    );
  }
}

/// Insignia del tipo de plugin: herramienta, skill, modo o pantalla.
class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final PluginKind kind;

  @override
  Widget build(final BuildContext context) {
    final (color, icon) = switch (kind) {
      PluginKind.tool => (ChronoxColors.primary, Icons.build_rounded),
      PluginKind.skill => (ChronoxColors.accent, Icons.school_outlined),
      PluginKind.mode => (ChronoxColors.warning, Icons.layers_outlined),
      PluginKind.provider => (ChronoxColors.success, Icons.hub_outlined),
      PluginKind.surface => (ChronoxColors.accent, Icons.widgets_outlined),
    };

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(ChronoxRadius.sm),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// Muestra la pantalla de un plugin a pantalla completa.
///
/// La navegación se hace aquí y no dentro del plugin para que ningún plugin pueda
/// quedarse con la barra del sistema ni abrir rutas arbitrarias.
Future<void> openPluginSurface(
  final BuildContext context, {
  required final PluginSurface surface,
  required final String pluginId,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      // `PluginSurfaceHost` ya aporta `Scaffold`, barra superior y tema: aquí
      // solo se empuja la ruta.
      builder: (final context) =>
          PluginSurfaceHost(surface: surface, pluginId: pluginId),
    ),
  );
}
