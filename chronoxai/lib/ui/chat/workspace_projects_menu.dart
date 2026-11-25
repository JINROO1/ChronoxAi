import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme.dart';
import '../../platform/project_export_channel.dart';
import '../settings/settings_screen.dart';
import '../state/app_state.dart';

/// Workspace project manager. Projects are stored in `<workspace>/projects/`.
Future<void> showWorkspaceProjectsMenu(
  BuildContext context,
  WidgetRef ref,
) async {
  final runtime = await ref.read(localRuntimeProvider.future);
  if (!context.mounted) return;
  final projectsDir = Directory(p.join(runtime.hostWorkspace, 'projects'));
  await projectsDir.create(recursive: true);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ChronoxColors.backgroundElevated,
    builder: (_) => _ProjectsSheet(
      root: projectsDir,
      workspaceRoot: runtime.hostWorkspace,
      ref: ref,
    ),
  );
}

class _ProjectsSheet extends StatefulWidget {
  const _ProjectsSheet(
      {required this.root, required this.workspaceRoot, required this.ref});
  final Directory root;
  final String workspaceRoot;
  final WidgetRef ref;

  @override
  State<_ProjectsSheet> createState() => _ProjectsSheetState();
}

class _ProjectsSheetState extends State<_ProjectsSheet> {
  List<Directory> _projects = <Directory>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final entries = await widget.root.list(followLinks: false).toList();
    if (!mounted) return;
    setState(() {
      _projects = entries.whereType<Directory>().toList()
        ..sort((a, b) => p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase()));
      _loading = false;
    });
  }

  Future<void> _create() async {
    final name = await _askName('Crear proyecto');
    if (name == null) return;
    final directory = Directory(p.join(widget.root.path, _safeName(name)));
    if (await directory.exists()) {
      _message('Ya existe un proyecto con ese nombre.');
      return;
    }
    await directory.create(recursive: true);
    await File(p.join(directory.path, '.chronox-project.json')).writeAsString(
      jsonEncode(<String, Object?>{'name': name.trim(), 'lastSessionId': null}),
    );
    await _refresh();
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 64,
            decoration:
                const InputDecoration(labelText: 'Nombre del proyecto')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Guardar')),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }

  String _safeName(String name) {
    final safe = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (safe.isEmpty || safe == '.' || safe == '..')
      throw ArgumentError('Nombre no válido.');
    return safe;
  }

  Future<void> _rename(Directory project) async {
    final current = await _metadata(project);
    final name = await _askName('Renombrar proyecto', initial: current.name);
    if (name == null) return;
    final target = Directory(p.join(widget.root.path, _safeName(name)));
    if (await target.exists() && target.path != project.path) {
      _message('Ya existe un proyecto con ese nombre.');
      return;
    }
    if (target.path != project.path) await project.rename(target.path);
    await _writeMetadata(target, current.sessionId, name);
    await _refresh();
  }

  Future<void> _delete(Directory project) async {
    final activeWorkspace = widget.ref.read(sessionProvider)?.workspaceDir.path;
    if (activeWorkspace != null &&
        p.normalize(activeWorkspace) == p.normalize(project.path)) {
      _message('No se puede eliminar el proyecto de la sesión activa.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar proyecto'),
        content: Text(
            '¿Eliminar permanentemente “${p.basename(project.path)}” y todos sus archivos?'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirmed == true) {
      await project.delete(recursive: true);
      await _refresh();
    }
  }

  Future<void> _resume(Directory project) async {
    final metadata = await _metadata(project);
    if (!mounted) return;
    Navigator.of(context).pop();
    await showNewSessionDialog(
      context,
      widget.ref,
      sessionId: metadata.sessionId,
      workspacePath: project.path,
      projectPath: project.path,
    );
  }

  Future<void> _export(Directory project) async {
    try {
      final archive = Archive();
      await for (final entity
          in project.list(recursive: true, followLinks: false)) {
        final relative =
            p.relative(entity.path, from: project.path).replaceAll('\\', '/');
        if (entity is File) {
          archive.addFile(ArchiveFile(
              relative, await entity.length(), await entity.readAsBytes()));
        } else if (entity is Directory) {
          archive.addFile(ArchiveFile('$relative/', 0, const <int>[]));
        }
      }
      final bytes = ZipEncoder().encode(archive);
      final temp =
          await Directory.systemTemp.createTemp('chronox-project-export-');
      final zip =
          File(p.join(temp.path, '${_safeName(p.basename(project.path))}.zip'));
      await zip.writeAsBytes(bytes, flush: true);
      final saved = await const ProjectExportChannel()
          .saveZip(zip.path, p.basename(zip.path));
      await temp.delete(recursive: true);
      if (mounted)
        _message(saved ? 'Proyecto exportado.' : 'Exportación cancelada.');
    } catch (error) {
      if (mounted) _message('No se pudo exportar el proyecto: $error');
    }
  }

  Future<({String name, String? sessionId})> _metadata(
      Directory project) async {
    final file = File(p.join(project.path, '.chronox-project.json'));
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (
        name: json['name'] as String? ?? p.basename(project.path),
        sessionId: json['lastSessionId'] as String?
      );
    } catch (_) {
      return (name: p.basename(project.path), sessionId: null);
    }
  }

  Future<void> _writeMetadata(
          Directory project, String? sessionId, String name) =>
      File(p.join(project.path, '.chronox-project.json')).writeAsString(
        jsonEncode(<String, Object?>{'name': name, 'lastSessionId': sessionId}),
      );

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .76,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(children: <Widget>[
                    const Expanded(
                        child: Text('Proyectos del Workspace',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w700))),
                    IconButton(
                        onPressed: _create,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        tooltip: 'Crear proyecto'),
                  ]),
                  const Text(
                      'Cada proyecto vive en workspace/projects y mantiene el último chat asociado.'),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _projects.isEmpty
                            ? const Center(
                                child: Text(
                                    'Aún no hay proyectos. Crea uno para empezar.'))
                            : ListView.builder(
                                itemCount: _projects.length,
                                itemBuilder: (context, index) {
                                  final project = _projects[index];
                                  return FutureBuilder<
                                      ({String name, String? sessionId})>(
                                    future: _metadata(project),
                                    builder: (context, snapshot) {
                                      final metadata = snapshot.data;
                                      return ListTile(
                                        leading:
                                            const Icon(Icons.folder_outlined),
                                        title: Text(metadata?.name ??
                                            p.basename(project.path)),
                                        subtitle: Text(
                                            metadata?.sessionId == null
                                                ? project.path
                                                : 'Chat guardado disponible'),
                                        onTap: () => _resume(project),
                                        trailing: PopupMenuButton<String>(
                                          tooltip: 'Acciones del proyecto',
                                          onSelected: (value) {
                                            switch (value) {
                                              case 'resume':
                                                _resume(project);
                                              case 'rename':
                                                _rename(project);
                                              case 'export':
                                                _export(project);
                                              case 'delete':
                                                _delete(project);
                                            }
                                          },
                                          itemBuilder: (_) =>
                                              const <PopupMenuEntry<String>>[
                                            PopupMenuItem(
                                                value: 'resume',
                                                child: Text('Reanudar')),
                                            PopupMenuItem(
                                                value: 'rename',
                                                child: Text('Renombrar')),
                                            PopupMenuItem(
                                                value: 'export',
                                                child: Text(
                                                    'Exportar al almacenamiento')),
                                            PopupMenuItem(
                                                value: 'delete',
                                                child: Text('Eliminar')),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                }),
                  ),
                ]),
          ),
        ),
      );
}
