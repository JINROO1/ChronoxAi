import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/llm/local_model_store.dart';
import '../../platform/android_model_file_picker.dart';
import '../state/app_state.dart';

class LocalModelsScreen extends ConsumerStatefulWidget {
  const LocalModelsScreen({super.key});

  @override
  ConsumerState<LocalModelsScreen> createState() => _LocalModelsScreenState();
}

class _LocalModelsScreenState extends ConsumerState<LocalModelsScreen> {
  final LocalModelStore _store = LocalModelStore();
  List<LocalModelInstallation> _installed = const <LocalModelInstallation>[];
  final Map<String, ModelTransferProgress> _progress =
      <String, ModelTransferProgress>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final installed = await _store.installedModels();
      if (mounted) setState(() => _installed = installed);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _download(LocalModelSpec spec) async {
    setState(() {
      _busy = true;
      _error = null;
      _progress[spec.id] = const ModelTransferProgress(received: 0, total: 0);
    });
    try {
      await _store.download(
        spec,
        onProgress: (final progress) {
          if (!mounted) return;
          final previous = _progress[spec.id];
          if (previous == null ||
              progress.received == progress.total ||
              progress.fraction - previous.fraction >= 0.01) {
            setState(() => _progress[spec.id] = progress);
          }
        },
      );
      await _refresh();
    } catch (error) {
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
    setState(() {
      _busy = true;
      _error = null;
    });
    File? picked;
    try {
      picked = await const AndroidModelFilePicker().pickModel();
      if (picked == null) return;
      await _store.importFile(picked);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (picked != null && await picked.exists()) await picked.delete();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _use(LocalModelSpec spec) async {
    final settings = ref.read(providerSettingsProvider);
    ref.read(providerSettingsProvider.notifier).state = settings.copyWith(
      kind: ProviderKind.local,
      model: spec.id,
      baseUrl: '',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('${spec.label} seleccionado como modelo local.')),
      );
    }
  }

  Future<void> _remove(LocalModelSpec spec) async {
    final settings = ref.read(providerSettingsProvider);
    if (settings.kind == ProviderKind.local && settings.model == spec.id) {
      setState(() => _error =
          'Selecciona otro proveedor o modelo antes de eliminar el modelo activo.');
      return;
    }
    await _store.remove(spec);
    await _refresh();
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
            'Descarga o importa un GGUF. El archivo se guarda en el almacenamiento privado '
            'de ChronoxAI; su tamaño y SHA-256 se verifican antes de habilitarlo. '
            'La generación local no contacta a Ollama ni a un proveedor remoto.',
            style: TextStyle(color: ChronoxColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Importar GGUF desde el dispositivo'),
          ),
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
            Text('${_formatBytes(spec.bytes)} · Apache-2.0 · GGUF Q4_K_M',
                style: const TextStyle(color: ChronoxColors.textMuted)),
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
                    label: Text(active ? 'En uso' : 'Usar localmente'),
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
