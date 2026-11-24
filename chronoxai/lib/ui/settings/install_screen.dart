import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/runtime/local_runtime.dart';
import '../../data/runtime/rootfs_installer.dart';
import '../state/app_state.dart';
import '../widgets/chronox_widgets.dart';

/// Instalación del sistema Linux (Debian) dentro de la app.
///
/// La pantalla existe porque el primer arranque **no** puede descargar 120 MB a
/// escondidas: el usuario tiene que ver cuánto baja, poder cancelar y saber si
/// algo falló. Y en datos móviles, decidirlo él.
class InstallScreen extends ConsumerStatefulWidget {
  const InstallScreen({super.key});

  @override
  ConsumerState<InstallScreen> createState() => _InstallScreenState();
}

class _InstallScreenState extends ConsumerState<InstallScreen> {
  RootfsInstaller? _installer;
  InstallProgress? _progresso;
  InstallResult? _resultado;
  bool _instalando = false;

  Future<void> _instalar(final LocalRuntime runtime) async {
    final installer = RootfsInstaller(paths: runtime.paths);
    setState(() {
      _installer = installer;
      _instalando = true;
      _resultado = null;
      _progresso = const InstallProgress(phase: InstallPhase.resolving);
    });

    // La ABI real del dispositivo decide qué variante de la imagen se pide. Si
    // el canal nativo no responde, se asume arm64: es el caso de todos los
    // móviles Android modernos y el fallback no es peor que fallar.
    final facts = await runtime.facts();
    final abi = facts.abi.isEmpty ? 'arm64-v8a' : facts.abi;
    final resultado = await installer.install(
      architecture: RootfsInstaller.architectureFor(abi),
      onProgress: (final progreso) {
        if (mounted) setState(() => _progresso = progreso);
      },
    );

    if (!mounted) return;
    setState(() {
      _instalando = false;
      _resultado = resultado;
    });

    if (resultado.success) {
      // El estado del runtime está cacheado: hay que invalidarlo o la app
      // seguiría diciendo que falta el sistema operativo.
      ref.invalidate(localRuntimeStatusProvider);
      ref.invalidate(localRuntimeProvider);
    }
  }

  @override
  Widget build(final BuildContext context) {
    final runtimeAsync = ref.watch(localRuntimeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sistema Linux')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
        children: <Widget>[
          runtimeAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (final error, final _) => GlassPanel(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No se pudo leer el estado del dispositivo:\n$error',
                style: const TextStyle(color: ChronoxColors.danger),
              ),
            ),
            data: _contenido,
          ),
        ],
      ),
    );
  }

  Widget _contenido(final LocalRuntime runtime) {
    final instalado = runtime.paths.looksInstalled;
    final progreso = _progresso;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GlassPanel(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    instalado
                        ? Icons.check_circle_outline_rounded
                        : Icons.download_for_offline_outlined,
                    color: instalado
                        ? ChronoxColors.success
                        : ChronoxColors.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      instalado ? 'Debian instalado' : 'Instalar Debian',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                instalado
                    ? 'El contenedor está listo. Puedes ejecutar comandos desde '
                        'el chat o la terminal.'
                    : 'Chronox descarga la imagen oficial de Debian (unos 120 MB) '
                        'y la desempaqueta en el almacenamiento privado de la '
                        'app. Necesita conexión; con datos móviles puede '
                        'consumir cuota.',
                style: const TextStyle(
                  color: ChronoxColors.textMuted,
                  height: 1.45,
                ),
              ),
              if (!instalado) ...<Widget>[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _instalando ? null : () => _instalar(runtime),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    _instalando ? 'Instalando…' : 'Descargar e instalar',
                  ),
                ),
              ],
            ],
          ),
        ),
        if (progreso != null && _instalando) ...<Widget>[
          const SizedBox(height: 14),
          _Progreso(progreso: progreso),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => _installer?.cancel(),
            icon: const Icon(Icons.close_rounded),
            label: const Text('Cancelar instalación'),
          ),
        ],
        if (_resultado != null && !_resultado!.success) ...<Widget>[
          const SizedBox(height: 14),
          GlassPanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Row(
                  children: <Widget>[
                    Icon(Icons.error_outline_rounded,
                        color: ChronoxColors.danger),
                    SizedBox(width: 8),
                    Text(
                      'No se pudo instalar',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  _resultado!.message,
                  style: const TextStyle(
                    color: ChronoxColors.textMuted,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (instalado) ...<Widget>[
          const SizedBox(height: 14),
          GlassPanel(
            padding: const EdgeInsets.all(16),
            child: Text(
              _descripcionInstalacion(runtime),
              style: const TextStyle(color: ChronoxColors.textMuted),
            ),
          ),
        ],
      ],
    );
  }

  String _descripcionInstalacion(final LocalRuntime runtime) {
    final metadatos = RootfsInstaller(paths: runtime.paths).installedImage();
    if (metadatos == null) return 'Instalación local sin metadatos.';
    final fecha = metadatos['installedAt'] as String?;
    final arquitectura = metadatos['architecture'] as String? ?? 'arm64';
    final legible =
        fecha == null ? 'fecha desconocida' : fecha.split('T').first;
    return 'Variante $arquitectura · instalado el $legible';
  }
}

/// Barra de progreso con la fase actual y el detalle del último fichero.
class _Progreso extends StatelessWidget {
  const _Progreso({required this.progreso});

  final InstallProgress progreso;

  @override
  Widget build(final BuildContext context) {
    final fraccion = progreso.fraction;
    final megas = progreso.bytesTotal <= 0
        ? ''
        : '${_mb(progreso.bytesDone)} de ${_mb(progreso.bytesTotal)} MB';

    return GlassPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  progreso.phase.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (fraccion != null)
                Text(
                  '${(fraccion * 100).toStringAsFixed(0)} %',
                  style: const TextStyle(color: ChronoxColors.accent),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: fraccion,
              minHeight: 8,
              backgroundColor: ChronoxColors.border,
            ),
          ),
          if (megas.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              megas,
              style: const TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
          if (progreso.layerCount > 0) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'Capa ${progreso.layerIndex} de ${progreso.layerCount}',
              style: const TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
          if (progreso.currentEntry.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              progreso.currentEntry,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _mb(final int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);
}
