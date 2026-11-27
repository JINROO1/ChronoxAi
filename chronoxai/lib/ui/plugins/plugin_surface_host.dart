import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/plugins/plugin_api.dart';

/// Contenedor que monta la pantalla de un plugin.
///
/// Responsabilidades del host (y no del plugin):
/// * `Scaffold`, `SafeArea`, barra superior con el título del plugin;
/// * construir el `PluginSurfaceScope`;
/// * capturar errores de construcción para que un plugin roto no tumbe la app;
/// * aplicar el tema de la app, de modo que la pantalla herede colores, tipografía
///   y radios sin que el autor los escriba.
class PluginSurfaceHost extends StatefulWidget {
  const PluginSurfaceHost({
    super.key,
    required this.surface,
    required this.pluginId,
    this.onOpenTerminal,
    this.appBarActions = const <Widget>[],
  });

  final PluginSurface surface;
  final String pluginId;
  final Future<void> Function()? onOpenTerminal;
  final List<Widget> appBarActions;

  @override
  State<PluginSurfaceHost> createState() => _PluginSurfaceHostState();
}

class _PluginSurfaceHostState extends State<PluginSurfaceHost> {
  Object? _buildError;

  void _rebuild() {
    if (!mounted) return;
    setState(() => _buildError = null);
  }

  void _showSnackBar(final String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _openTerminal() async {
    final callback = widget.onOpenTerminal;
    if (callback != null) await callback();
  }

  @override
  Widget build(final BuildContext context) {
    final scope = PluginSurfaceScope(
      pluginId: widget.pluginId,
      setState: _rebuild,
      showSnackBar: _showSnackBar,
      openTerminal: _openTerminal,
    );

    return Scaffold(
      backgroundColor: ChronoxColors.background,
      appBar: AppBar(
        titleSpacing: 4,
        title: Row(
          children: <Widget>[
            Icon(widget.surface.icon, size: 19, color: ChronoxColors.primary),
            const SizedBox(width: ChronoxSpacing.sm),
            Flexible(
                child: Text(widget.surface.label,
                    overflow: TextOverflow.ellipsis)),
            const SizedBox(width: ChronoxSpacing.sm),
            _PluginBadge(pluginId: widget.pluginId),
          ],
        ),
        actions: <Widget>[
          ...widget.appBarActions,
          const SizedBox(width: ChronoxSpacing.sm),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _buildError != null
            ? _PluginCrashView(
                pluginId: widget.pluginId,
                error: _buildError!,
                onRetry: _rebuild,
              )
            : _GuardedBuilder(
                onError: (final error) {
                  // Un plugin roto nunca debe tumbar la app: se captura y se
                  // muestra un aviso con opción de reintentar.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _buildError = error);
                  });
                  return const SizedBox.shrink();
                },
                builder: () => widget.surface.builder(context, scope),
              ),
      ),
    );
  }
}

/// Ejecuta el `builder` y convierte una excepción en un error capturable.
class _GuardedBuilder extends StatelessWidget {
  const _GuardedBuilder({required this.builder, required this.onError});

  final Widget Function() builder;
  final Widget Function(Object error) onError;

  @override
  Widget build(final BuildContext context) {
    try {
      return builder();
    } catch (error) {
      return onError(error);
    }
  }
}

/// Etiqueta discreta que indica que la pantalla viene de un plugin.
class _PluginBadge extends StatelessWidget {
  const _PluginBadge({required this.pluginId});

  final String pluginId;

  @override
  Widget build(final BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ChronoxColors.accent.withOpacity(0.14),
        borderRadius: ChronoxRadius.pill,
        border: Border.all(color: ChronoxColors.accent.withOpacity(0.35)),
      ),
      child: Text(
        'plugin',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: ChronoxColors.accent.withOpacity(0.95),
        ),
      ),
    );
  }
}

/// Pantalla que se muestra cuando un plugin lanza una excepción al construir.
class _PluginCrashView extends StatelessWidget {
  const _PluginCrashView({
    required this.pluginId,
    required this.error,
    required this.onRetry,
  });

  final String pluginId;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(final BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ChronoxSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.extension_off_outlined,
              size: 44,
              color: ChronoxColors.danger,
            ),
            const SizedBox(height: ChronoxSpacing.md),
            Text(
              'El plugin "$pluginId" falló',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: ChronoxSpacing.sm),
            Text(
              '$error',
              style: ChronoxTheme.monoSmall
                  .copyWith(color: ChronoxColors.textMuted),
              textAlign: TextAlign.center,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: ChronoxSpacing.lg),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Muestra una rejilla con las pantallas que aportan los plugins instalados.
///
/// Se usa en Ajustes → Plugins para que el usuario descubra qué plugins añaden
/// interfaz propia.
class PluginSurfaceGrid extends StatelessWidget {
  const PluginSurfaceGrid({
    super.key,
    required this.entries,
    required this.onOpen,
  });

  /// Pares (id del plugin, superficie).
  final List<({String pluginId, PluginSurface surface})> entries;
  final void Function(String pluginId) onOpen;

  @override
  Widget build(final BuildContext context) {
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(ChronoxSpacing.md),
        child: Text(
          'Ningún plugin aporta una pantalla todavía.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: ChronoxColors.textMuted),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(ChronoxSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: ChronoxSpacing.sm,
        crossAxisSpacing: ChronoxSpacing.sm,
        childAspectRatio: 1.6,
      ),
      itemCount: entries.length,
      itemBuilder: (final context, final index) {
        final entry = entries[index];
        return _SurfaceTile(
          surface: entry.surface,
          onTap: () => onOpen(entry.pluginId),
        );
      },
    );
  }
}

class _SurfaceTile extends StatelessWidget {
  const _SurfaceTile({required this.surface, required this.onTap});

  final PluginSurface surface;
  final VoidCallback onTap;

  @override
  Widget build(final BuildContext context) {
    return Material(
      color: ChronoxColors.surfaceHigh,
      borderRadius: ChronoxRadius.card,
      child: InkWell(
        onTap: onTap,
        borderRadius: ChronoxRadius.card,
        child: Container(
          padding: const EdgeInsets.all(ChronoxSpacing.md),
          decoration: BoxDecoration(
            borderRadius: ChronoxRadius.card,
            border: Border.all(color: ChronoxColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Icon(surface.icon, color: ChronoxColors.primary, size: 22),
              Text(
                surface.label,
                style: Theme.of(context).textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
