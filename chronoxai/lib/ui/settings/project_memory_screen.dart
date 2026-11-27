import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../domain/agent/project_memory.dart';
import '../widgets/chronox_widgets.dart';

/// Manual review and control surface for the current workspace's durable memory.
class ProjectMemoryScreen extends StatefulWidget {
  const ProjectMemoryScreen({
    required this.store,
    required this.workspacePath,
    super.key,
  });

  final ProjectMemoryStore store;
  final String workspacePath;

  @override
  State<ProjectMemoryScreen> createState() => _ProjectMemoryScreenState();
}

class _ProjectMemoryScreenState extends State<ProjectMemoryScreen> {
  @override
  Widget build(final BuildContext context) {
    final store = widget.store;
    final entries = store.entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memoria del proyecto'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Copiar exportación JSON',
            onPressed: _export,
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            tooltip: 'Borrar toda la memoria',
            onPressed:
                entries.isEmpty && store.loadWarning == null ? null : _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Añadir memoria'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
        children: <Widget>[
          if (store.loadWarning != null)
            GlassPanel(
              padding: const EdgeInsets.all(12),
              child: Text(
                'No se pudo leer el archivo de memoria. Para proteger los '
                'datos existentes, las escrituras están bloqueadas. Usa '
                '“Borrar toda la memoria” para reiniciar. ${store.loadWarning}',
                style: const TextStyle(color: ChronoxColors.warning),
              ),
            ),
          if (store.rejectedOnLoad > 0)
            GlassPanel(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${store.rejectedOnLoad} entradas no válidas o con posible '
                'secreto se omitieron al cargar.',
                style: const TextStyle(color: ChronoxColors.warning),
              ),
            ),
          GlassPanel(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Usar memoria en los turnos'),
                  subtitle: const Text(
                    'Solo se inyectan notas relevantes y dentro de un límite.',
                  ),
                  value: store.enabled,
                  onChanged: _setEnabled,
                ),
                const Divider(color: ChronoxColors.border),
                Text(
                  'Workspace: ${widget.workspacePath}',
                  style: const TextStyle(
                    color: ChronoxColors.textMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Se guarda en almacenamiento privado de la app, aislado por '
                  'workspace; no se escriben archivos del proyecto ni se '
                  'guardan transcripciones completas. No añadas contraseñas, '
                  'claves o tokens. Las notas son contexto no confiable y se '
                  'pueden editar, exportar o borrar aquí.',
                  style: TextStyle(
                    color: ChronoxColors.textSecondary,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('Excluir del contexto'),
          GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: <Widget>[
                SettingsRow(
                  icon: Icons.topic_outlined,
                  title: 'Temas excluidos',
                  subtitle: store.excludedTopics.isEmpty
                      ? 'Ninguno'
                      : store.excludedTopics.join(', '),
                  onTap: () => _editExclusions(topics: true),
                ),
                const Divider(height: 1, color: ChronoxColors.border),
                SettingsRow(
                  icon: Icons.folder_off_outlined,
                  title: 'Fuentes/rutas excluidas',
                  subtitle: store.excludedSources.isEmpty
                      ? 'Ninguna'
                      : store.excludedSources.join(', '),
                  onTap: () => _editExclusions(topics: false),
                ),
              ],
            ),
          ),
          const SectionLabel('Notas guardadas'),
          if (entries.isEmpty)
            const GlassPanel(
              padding: EdgeInsets.all(16),
              child: Text(
                'Aún no hay notas. Añade solo información útil, con una fuente '
                'que permita verificarla y una confianza honesta.',
                style: TextStyle(color: ChronoxColors.textSecondary),
              ),
            ),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassPanel(
                padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _kindLabel(entry.kind),
                            style: const TextStyle(
                              color: ChronoxColors.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.text,
                            style: const TextStyle(
                              color: ChronoxColors.textPrimary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Fuente: ${entry.source} · '
                            '${entry.createdAt.toLocal().toIso8601String().split('T').first} · '
                            'Confianza ${(entry.confidence * 100).round()}%',
                            style: const TextStyle(
                              color: ChronoxColors.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Editar nota',
                      onPressed: () => _edit(entry),
                      icon: const Icon(Icons.edit_outlined, size: 19),
                    ),
                    IconButton(
                      tooltip: 'Borrar nota',
                      onPressed: () => _delete(entry),
                      icon: const Icon(Icons.delete_outline, size: 19),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _setEnabled(final bool enabled) async {
    if (!widget.store.canWrite) return;
    await widget.store.configure(
      enabled: enabled,
      excludedTopics: widget.store.excludedTopics,
      excludedSources: widget.store.excludedSources,
    );
    if (mounted) setState(() {});
  }

  Future<void> _editExclusions({required final bool topics}) async {
    if (!widget.store.canWrite) return;
    final current =
        topics ? widget.store.excludedTopics : widget.store.excludedSources;
    final controller = TextEditingController(text: current.join(', '));
    final value = await showDialog<String>(
      context: context,
      builder: (final dialogContext) => AlertDialog(
        title: Text(topics ? 'Excluir temas' : 'Excluir fuentes o rutas'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Separados por coma',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final list = value
        .split(',')
        .map((final item) => item.trim())
        .where((final item) => item.isNotEmpty);
    await widget.store.configure(
      enabled: widget.store.enabled,
      excludedTopics: topics ? list : widget.store.excludedTopics,
      excludedSources: topics ? widget.store.excludedSources : list,
    );
    if (mounted) setState(() {});
  }

  Future<void> _edit([final ProjectMemoryEntry? entry]) async {
    if (!widget.store.canWrite) return;
    final kindController = ValueNotifier<ProjectMemoryKind>(
      entry?.kind ?? ProjectMemoryKind.fact,
    );
    final textController = TextEditingController(text: entry?.text ?? '');
    final sourceController = TextEditingController(text: entry?.source ?? '');
    final confidenceController = TextEditingController(
      text: (entry?.confidence ?? 0.8).toString(),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (final dialogContext) => AlertDialog(
        title: Text(entry == null ? 'Añadir nota' : 'Editar nota'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ValueListenableBuilder<ProjectMemoryKind>(
                valueListenable: kindController,
                builder: (final context, final kind, final _) =>
                    DropdownButtonFormField<ProjectMemoryKind>(
                  value: kind,
                  decoration: const InputDecoration(labelText: 'Categoría'),
                  items: <DropdownMenuItem<ProjectMemoryKind>>[
                    for (final value in ProjectMemoryKind.values)
                      DropdownMenuItem<ProjectMemoryKind>(
                        value: value,
                        child: Text(_kindLabel(value)),
                      ),
                  ],
                  onChanged: (final value) {
                    if (value != null) kindController.value = value;
                  },
                ),
              ),
              TextField(
                controller: textController,
                maxLength: ProjectMemoryStore.maxTextLength,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Nota',
                  hintText: 'Un hecho, preferencia o recuerdo confirmado',
                ),
              ),
              TextField(
                controller: sourceController,
                maxLength: ProjectMemoryStore.maxSourceLength,
                decoration: const InputDecoration(
                  labelText: 'Fuente / procedencia',
                  hintText: 'Ruta y línea o confirmación explícita del usuario',
                ),
              ),
              TextField(
                controller: confidenceController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Confianza (0–1)',
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'No se guarda una conversación completa. Guarda solo lo que '
                'deba sobrevivir y que tenga fuente verificable.',
                style: TextStyle(fontSize: 11, color: ChronoxColors.textMuted),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (saved == true) {
      try {
        final confidence = double.parse(confidenceController.text.trim());
        if (entry == null) {
          await widget.store.add(
            kind: kindController.value,
            text: textController.text,
            source: sourceController.text,
            confidence: confidence,
          );
        } else {
          await widget.store.update(
            entry.id,
            kind: kindController.value,
            text: textController.text,
            source: sourceController.text,
            confidence: confidence,
          );
        }
        if (mounted) setState(() {});
      } catch (error) {
        _message('No se guardó: $error');
      }
    }
    kindController.dispose();
    textController.dispose();
    sourceController.dispose();
    confidenceController.dispose();
  }

  Future<void> _delete(final ProjectMemoryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (final dialogContext) => AlertDialog(
        title: const Text('Borrar esta nota?'),
        content: Text('Se eliminará “${entry.text}”.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.remove(entry.id);
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (final dialogContext) => AlertDialog(
        title: const Text('Borrar toda la memoria?'),
        content: const Text(
          'Se borrarán notas, filtros y configuración de memoria de este workspace. '
          'Esta acción no se puede deshacer.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Borrar todo'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.clear();
    if (mounted) setState(() {});
  }

  Future<void> _export() async {
    await Clipboard.setData(ClipboardData(text: widget.store.exportJson()));
    _message('Exportación JSON copiada al portapapeles.');
  }

  void _message(final String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static String _kindLabel(final ProjectMemoryKind kind) => switch (kind) {
        ProjectMemoryKind.fact => 'HECHO',
        ProjectMemoryKind.preference => 'PREFERENCIA',
        ProjectMemoryKind.conversation => 'CONFIRMADO EN CONVERSACIÓN',
      };
}
