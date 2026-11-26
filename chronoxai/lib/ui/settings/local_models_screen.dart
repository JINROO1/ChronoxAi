import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/llm/local_llm_provider.dart';
import '../../data/llm/local_model_store.dart';
import '../../platform/android_model_file_picker.dart';
import '../../platform/android_local_inference_engine.dart';
import '../../platform/android_local_storage_info.dart';
import '../../platform/android_model_download_notifications.dart';
import '../../platform/android_permissions.dart';
import '../state/app_state.dart';

class LocalModelsScreen extends ConsumerStatefulWidget {
  const LocalModelsScreen({
    super.key,
    this.store,
    this.loadInstalledModels,
    this.availableStorageBytes,
    this.pickModelFile,
  });

  final LocalModelStore? store;
  final Future<List<LocalModelInstallation>> Function()? loadInstalledModels;
  final Future<int?> Function()? availableStorageBytes;
  final Future<File?> Function()? pickModelFile;

  @override
  ConsumerState<LocalModelsScreen> createState() => _LocalModelsScreenState();
}

class _LocalModelsScreenState extends ConsumerState<LocalModelsScreen> {
  late final LocalModelStore _store;
  List<LocalModelInstallation> _installed = const <LocalModelInstallation>[];
  final Map<String, ModelTransferProgress> _progress =
      <String, ModelTransferProgress>{};
  bool _busy = false;
  bool _importing = false;
  bool _importCopying = false;
  bool _importCancelled = false;
  String? _checkingModelId;
  int? _availableBytes;
  Map<String, Object?>? _deviceDiagnostics;
  String? _error;
  StreamSubscription<LocalModelTransferState>? _transferSubscription;
  final AndroidModelDownloadNotifications _downloadNotifications =
      const AndroidModelDownloadNotifications();

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? LocalModelStore();
    _transferSubscription = LocalModelStore.transferEvents.listen(_onTransferState);
    _onTransferState(LocalModelStore.transferState, notifySystem: false);
    _refresh();
  }

  @override
  void dispose() {
    _transferSubscription?.cancel();
    super.dispose();
  }

  void _onTransferState(
    LocalModelTransferState transfer, {
    bool notifySystem = true,
  }) {
    final modelId = transfer.modelId;
    if (modelId == null) return;
    if (mounted) {
      setState(() {
        _busy = transfer.active;
        if (transfer.active && transfer.progress != null) {
          _progress[modelId] = transfer.progress!;
          _error = null;
        } else {
          _progress.remove(modelId);
          if (transfer.error != null) _error = transfer.error;
        }
      });
    }
    if (notifySystem && !transfer.active && transfer.error == null && mounted) {
      unawaited(_refresh());
    }
  }

  Future<int?> _readAvailableBytes() =>
      widget.availableStorageBytes?.call() ??
      const AndroidLocalStorageInfo().availableBytes();

  Future<File?> _pickModelFile() =>
      widget.pickModelFile?.call() ??
      const AndroidModelFilePicker().pickModel();

  Future<void> _refresh() async {
    try {
      final installed = widget.loadInstalledModels != null
          ? await widget.loadInstalledModels!.call()
          : await _store.installedModels();
      final availableBytes = await _readAvailableBytes();
      Map<String, Object?>? diagnostics;
      try {
        diagnostics = await const AndroidLocalStorageInfo().diagnostics();
      } catch (_) {
        // Diagnostics are optional and must never block model management.
      }
      if (mounted) {
        setState(() {
          _installed = installed;
          _availableBytes = availableBytes;
          _deviceDiagnostics = diagnostics;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Widget _diagnosticsCard() {
    final session = ref.watch(sessionProvider);
    final provider = session?.provider;
    final localEngine = provider is LocalLlmProvider &&
            provider.engine is AndroidLocalInferenceEngine
        ? provider.engine as AndroidLocalInferenceEngine
        : null;
    final data = _deviceDiagnostics;
    int? value(String key) => data?[key] is int ? data![key] as int : null;
    final rss = value('rssBytes');
    final peakRss = value('peakRssBytes');
    final pss = value('pssBytes');
    final availableRam = value('availableRamBytes');
    final totalRam = value('totalRamBytes');
    final api = value('apiLevel');
    final abi = data?['abi'];

    return Card(
      color: ChronoxColors.backgroundElevated,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Mediciones del dispositivo',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            if (rss != null) Text('RSS actual: ${_formatBytes(rss)}'),
            if (peakRss != null)
              Text('Pico RSS del proceso: ${_formatBytes(peakRss)}'),
            if (pss != null) Text('PSS del proceso: ${_formatBytes(pss)}'),
            if (availableRam != null && totalRam != null)
              Text(
                  'RAM disponible: ${_formatBytes(availableRam)} / ${_formatBytes(totalRam)}'),
            if (api != null && abi is String)
              Text('Android API $api · ABI $abi'),
            if (localEngine?.lastLoadDuration case final duration?)
              Text('Última carga local: ${duration.inMilliseconds} ms'),
            if (localEngine?.lastGenerationMetrics case final metrics?)
              Text(
                'Última generación: ${metrics.generatedTokens} tokens · '
                '${metrics.elapsedMilliseconds} ms · '
                '${metrics.tokensPerSecond.toStringAsFixed(2)} tokens/s',
              ),
            const SizedBox(height: 8),
            const Text(
              'Las métricas describen este dispositivo y este proceso; no certifican por sí solas el perfil objetivo de 8 GB.',
              style: TextStyle(color: ChronoxColors.textMuted, fontSize: 12),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar mediciones'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _download(LocalModelSpec spec) async {
    if (!await _ensureSpace(spec) || !mounted) return;
    // Optional permission: if declined, the persistent in-app transfer state
    // still works and the download is never blocked.
    await const AndroidPermissions().requestNotifications();
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress[spec.id] = const ModelTransferProgress(received: 0, total: 0);
    });
    try {
      await _store.download(
        spec,
        onProgress: (final progress) {
          // This callback belongs to the transfer, not the route. Keep updating
          // the Android notification even after the user leaves this screen.
          unawaited(_downloadNotifications.showProgress(spec.label, progress));
          if (!mounted) return;
          final previous = _progress[spec.id];
          if (previous == null ||
              progress.received == progress.total ||
              progress.fraction - previous.fraction >= 0.01) {
            setState(() => _progress[spec.id] = progress);
          }
        },
      );
      await _downloadNotifications.showFinished(spec.label);
      await _refresh();
    } catch (error) {
      await _downloadNotifications.showFailed(spec.label, error.toString());
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress.remove(spec.id);
        });
      }
    }
  }

  Future<void> _import() async {
    _importCancelled = false;
    setState(() {
      _busy = true;
      _importing = true;
      _error = null;
    });
    File? picked;
    try {
      picked = await _pickModelFile();
      if (picked == null || _importCancelled || !mounted) return;
      final bytes = await picked.length();
      final spec = LocalModelSpec.catalog
          .where((final candidate) => candidate.bytes == bytes)
          .firstOrNull;
      if (spec == null) {
        throw const FileSystemException(
            'El tamaño no coincide con un modelo Qwen admitido.');
      }
      if (!await _ensureSpace(spec) || _importCancelled) return;
      setState(() => _importCopying = true);
      await _store.importFile(picked);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      try {
        if (picked != null && await picked.exists()) await picked.delete();
      } catch (error) {
        if (mounted)
          setState(() => _error = 'No se pudo limpiar la importación: $error');
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
            _importing = false;
            _importCopying = false;
          });
        }
      }
    }
  }

  void _cancelImport() {
    _importCancelled = true;
    _store.cancelDownload();
  }

  Future<bool> _ensureSpace(LocalModelSpec spec) async {
    final int available;
    try {
      final result = await _readAvailableBytes();
      if (result == null) {
        throw const FileSystemException(
            'Android no informó el almacenamiento disponible.');
      }
      available = result;
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            'No se pudo comprobar el espacio libre; no se inició la transferencia. $error');
      }
      return false;
    }

    const safetyMargin = 128 * 1024 * 1024;
    final replacing = _installed.any((final item) => item.spec.id == spec.id);
    final needed = spec.bytes + safetyMargin + (replacing ? spec.bytes : 0);
    if (mounted) setState(() => _availableBytes = available);
    if (available >= needed) return true;

    if (mounted) {
      setState(() => _error =
          'Espacio insuficiente: quedan ${_formatBytes(available)}; se requieren '
              'aproximadamente ${_formatBytes(needed)} para completar la operación de forma segura.');
    }
    return false;
  }

  Future<void> _use(LocalModelSpec spec) async {
    setState(() {
      _busy = true;
      _checkingModelId = spec.id;
      _error = null;
    });
    try {
      // Re-hash at the point of activation. The catalogue listing is cheap and
      // checks the manifest/length; loading never trusts those alone.
      final verifiedFile = await _store.fileForId(spec.id);
      if (verifiedFile == null) {
        throw const FileSystemException(
            'El modelo ya no está instalado o no figura en el manifiesto.');
      }
      if (!mounted) return;
      final settings = ref.read(providerSettingsProvider);
      ref.read(providerSettingsProvider.notifier).state = settings.copyWith(
        kind: ProviderKind.local,
        model: spec.id,
        baseUrl: '',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('${spec.label} verificado y seleccionado localmente.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _checkingModelId = null;
        });
      }
    }
  }

  Future<void> _remove(LocalModelSpec spec) async {
    if (_busy) return;
    final settings = ref.read(providerSettingsProvider);
    final activeProvider = ref.read(sessionProvider)?.provider;
    final modelInUse =
        activeProvider is LocalLlmProvider && activeProvider.model == spec.id;
    if (modelInUse ||
        (settings.kind == ProviderKind.local && settings.model == spec.id)) {
      setState(() => _error =
          'Selecciona otro proveedor o modelo antes de eliminar el modelo activo.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.remove(spec);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(providerSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Modelos sin conexión')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'La descarga inicial requiere Internet; también puedes importar un GGUF desde el teléfono. '
            'El archivo se guarda en el almacenamiento privado de ChronoxAI y se verifica por tamaño '
            'y SHA-256 antes de habilitarlo. La generación local no contacta Ollama ni a proveedores remotos. '
            'Los requisitos de RAM y la compatibilidad con teléfonos de 8 GB aún no están certificados; el tamaño del archivo no equivale a la memoria necesaria.',
            style: TextStyle(color: ChronoxColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Importar GGUF desde el dispositivo'),
          ),
          if (_importing) ...<Widget>[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            if (_importCopying)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _cancelImport,
                  icon: const Icon(Icons.close),
                  label: const Text('Cancelar copia'),
                ),
              ),
          ],
          _diagnosticsCard(),
          const SizedBox(height: 8),
          if (_availableBytes != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Almacenamiento interno disponible: ${_formatBytes(_availableBytes!)}',
              style: const TextStyle(color: ChronoxColors.textMuted),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: ChronoxColors.danger)),
          ],
          const SizedBox(height: 16),
          for (final spec in LocalModelSpec.catalog) _modelCard(spec, settings),
        ],
      ),
    );
  }

  Widget _modelCard(LocalModelSpec spec, ProviderSettings settings) {
    final installation =
        _installed.where((final item) => item.spec.id == spec.id).firstOrNull;
    final active =
        settings.kind == ProviderKind.local && settings.model == spec.id;
    final progress = _progress[spec.id];
    return Card(
      color: ChronoxColors.backgroundElevated,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(spec.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${_formatBytes(spec.bytes)} · ${spec.format} ${spec.quantization} · ${spec.license}',
              style: const TextStyle(color: ChronoxColors.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              'Contexto configurado: ${spec.contextWindow} tokens · SHA-256 ${spec.sha256.substring(0, 12)}…${spec.sha256.substring(spec.sha256.length - 8)}',
              style: const TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 11,
              ),
            ),
            Text(
              'Origen fijado: ${Uri.parse(spec.url).host} · revisión ${spec.revision.substring(0, 8)}',
              style: const TextStyle(
                color: ChronoxColors.textMuted,
                fontSize: 11,
              ),
            ),
            if (progress != null) ...<Widget>[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                  value: progress.total == 0 ? null : progress.fraction),
              const SizedBox(height: 4),
              Text(
                  '${_formatBytes(progress.received)} / ${_formatBytes(spec.bytes)}'),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _store.cancelDownload,
                  icon: const Icon(Icons.close),
                  label: const Text('Cancelar descarga'),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: <Widget>[
                if (installation == null)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _download(spec),
                    icon: const Icon(Icons.download),
                    label: const Text('Descargar'),
                  )
                else ...<Widget>[
                  FilledButton.icon(
                    onPressed: active || _busy ? null : () => _use(spec),
                    icon: Icon(active
                        ? Icons.check_circle
                        : Icons.play_circle_outline),
                    label: Text(
                      _checkingModelId == spec.id
                          ? 'Verificando…'
                          : active
                              ? 'En uso'
                              : 'Usar localmente',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _remove(spec),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Eliminar'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    final gigabytes = bytes / 1000000000;
    return gigabytes >= 1
        ? '${gigabytes.toStringAsFixed(2)} GB'
        : '${(bytes / 1000000).round()} MB';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
