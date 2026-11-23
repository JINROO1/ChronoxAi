import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../plugin_api.dart';
import '../plugin_runtime.dart';

/// Plugin de ejemplo que demuestra las dos cosas a la vez:
///
/// 1. **Aporta una herramienta** (`disk_usage`) que el agente puede invocar.
/// 2. **Aporta su propia pantalla**, con botón para refrescar y salida en vivo.
///
/// Sirve como plantilla: copiar este fichero, cambiar el manifest y el cuerpo de
/// la pantalla es todo lo necesario para crear un plugin nuevo.
class DiskUsagePlugin extends ChronoxPlugin {
  ShellSeam? _shell;
  final ValueNotifier<String> output = ValueNotifier<String>(
    'Pulsa "Analizar" para ver el uso de disco.',
  );
  bool _running = false;

  static PluginManifest get manifest => const PluginManifest(
    id: 'example-disk-usage',
    name: 'Uso de disco',
    version: '1.0.0',
    kind: PluginKind.surface,
    description:
        'Muestra qué ocupa espacio en el contenedor y lo expone al agente como '
        'la herramienta `disk_usage`.',
    author: 'Chronox AI (ejemplo)',
    capabilities: <PluginCapability>[PluginCapability.shell],
    icon: 'storage',
    surfaceLabel: 'Disco',
    surfaceOrder: 200,
    enabledByDefault: false,
  );

  @override
  Future<void> mount(final PluginContext context) async {
    // Guardamos el seam para usarlo tanto desde la herramienta como desde la UI.
    _shell = context.services.shell;

    context.provideTool(
      PluginTool(
        name: 'disk_usage',
        description:
            'Informa del espacio libre y de los directorios que más ocupan en '
            'el contenedor. Útil antes de instalar paquetes o limpiar caché.',
        requiresApproval: false,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{
              'type': 'string',
              'description': 'Directorio a analizar (por defecto /).',
            },
          },
          'additionalProperties': false,
        },
        execute: (final args) async {
          final path = (args['path'] as String?) ?? '/';
          final result = await _shell!.run(
            'df -h "$path" 2>/dev/null; echo "---"; '
            'du -sh "$path"/* 2>/dev/null | sort -rh | head -15',
            timeout: const Duration(seconds: 45),
          );
          return ToolOutcome(
            content: result.output.isEmpty
                ? 'No se pudo analizar "$path".'
                : result.output,
            isError: !result.isSuccess,
          );
        },
      ),
    );

    // La pantalla se registra con un builder que captura este plugin, de modo
    // que UI y herramienta comparten el mismo seam y el mismo estado.
    context.provideSurface(
      PluginSurface(
        label: 'Disco',
        icon: Icons.storage_outlined,
        order: 200,
        builder: (final context, final scope) =>
            _DiskUsageView(plugin: this, scope: scope),
      ),
    );
  }

  @override
  Future<void> unmount() async {
    _shell = null;
    output.dispose();
  }

  /// Ejecuta el análisis. Lo llaman la UI y (con otro formato) la herramienta.
  Future<void> analyze() async {
    final shell = _shell;
    if (shell == null || _running) return;

    _running = true;
    output.value = 'Analizando…';

    try {
      final result = await shell.run(
        // El `\$` escapa la interpolación de Dart: el shell debe recibir "$ ".
        'printf "\\n== Espacio en disco ==\\n"; df -h / 2>/dev/null; '
        'printf "\\n== Directorios más pesados ==\\n"; '
        'du -sh /* 2>/dev/null | sort -rh | head -12',
        timeout: const Duration(seconds: 60),
      );
      output.value = result.output.isEmpty
          ? 'Sin resultados. ¿Está instalado el contenedor Linux?'
          : result.output;
    } catch (e) {
      output.value = 'Error al analizar: $e';
    } finally {
      _running = false;
    }
  }
}

/// Pantalla del plugin.
///
/// No crea `Scaffold` ni `AppBar`: eso lo aporta `PluginSurfaceHost`. Aquí solo
/// hay contenido, y aun así hereda el tema de la app.
class _DiskUsageView extends StatelessWidget {
  const _DiskUsageView({required this.plugin, required this.scope});

  final DiskUsagePlugin plugin;
  final PluginSurfaceScope scope;

  @override
  Widget build(final BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ChronoxSpacing.md,
            ChronoxSpacing.md,
            ChronoxSpacing.md,
            ChronoxSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Espacio ocupado en el contenedor',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () async {
                  await plugin.analyze();
                  scope.setState();
                },
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Analizar'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(ChronoxSpacing.md),
            padding: const EdgeInsets.all(ChronoxSpacing.md),
            decoration: BoxDecoration(
              color: ChronoxColors.codeBackground,
              borderRadius: ChronoxRadius.card,
              border: Border.all(color: ChronoxColors.border),
            ),
            child: ValueListenableBuilder<String>(
              valueListenable: plugin.output,
              builder: (final context, final text, final _) {
                return SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      text,
                      style: ChronoxTheme.mono,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
