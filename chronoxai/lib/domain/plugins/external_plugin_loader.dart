import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'plugin_api.dart';
import 'plugin_runtime.dart';
import 'external_plugin_rpc.dart';

/// Carga los plugins JSON-RPC instalados en `.chronox/plugins/<id>/`.
/// Los manifiestos declaran capacidades y las herramientas siempre exigen
/// aprobación del usuario, independientemente de lo que anuncie el plugin.
abstract final class ExternalPluginLoader {
  static final RegExp _idPattern = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');

  static Future<List<String>> loadAndMount({
    required final Directory pluginDirectory,
    required final PluginHost host,
    required final Future<Process> Function(String guestScript) startProcess,
  }) async {
    if (!await pluginDirectory.exists()) return const <String>[];
    final mounted = <String>[];
    final directories = <Directory>[];
    await for (final entity in pluginDirectory.list(followLinks: false)) {
      if (entity is Directory) directories.add(entity);
    }
    directories.sort((final a, final b) => a.path.compareTo(b.path));

    for (final directory in directories) {
      final id = p.basename(directory.path);
      if (!_idPattern.hasMatch(id)) continue;
      final manifestFile = File(p.join(directory.path, 'manifest.json'));
      final script = File(p.join(directory.path, 'plugin.py'));
      if (!await manifestFile.exists() || !await script.exists()) continue;
      try {
        final json = jsonDecode(await manifestFile.readAsString());
        if (json is! Map<String, Object?>) continue;
        final manifest = PluginManifest.fromJson(json);
        if (manifest.id != id ||
            manifest.kind != PluginKind.tool ||
            !manifest.enabledByDefault ||
            host.plugins.any((final plugin) => plugin.manifest.id == id)) {
          continue;
        }
        final plugin = _ExternalToolPlugin(
          manifest: manifest,
          startProcess: startProcess,
          guestScript: '/workspace/.chronox/plugins/$id/plugin.py',
        );
        host.register(manifest, plugin, source: 'user');
        if (await host.mount(id)) mounted.add(id);
      } catch (_) {
        // Plugin mal formado o proceso que no inicia: el resto del runtime sigue.
      }
    }
    return List<String>.unmodifiable(mounted);
  }
}

class _ExternalToolPlugin extends ChronoxPlugin {
  _ExternalToolPlugin({
    required this.manifest,
    required this.startProcess,
    required this.guestScript,
  });

  @override
  final PluginManifest manifest;
  final Future<Process> Function(String guestScript) startProcess;
  final String guestScript;
  ExternalPluginRpc? _rpc;

  @override
  Future<void> mount(final PluginContext context) async {
    final process = await startProcess(guestScript);
    final rpc = ExternalPluginRpc(ProcessPluginTransport(process));
    _rpc = rpc;
    try {
      await rpc.request('initialize', <String, Object?>{
        'protocolVersion': '1.0',
        'manifest': manifest.toJson(),
      });
      final listed = await rpc.request('tools/list', const <String, Object?>{});
      final tools = listed['tools'];
      if (tools is! List) return;
      for (final raw in tools.whereType<Map<String, Object?>>()) {
        final remoteName = (raw['name'] as String?)?.trim() ?? '';
        if (remoteName.isEmpty) continue;
        final name = 'ext_${manifest.id}_'
            '${remoteName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';
        final schema = raw['inputSchema'];
        context.provideTool(PluginTool(
          name: name,
          description: (raw['description'] as String?) ?? remoteName,
          inputSchema: schema is Map<String, Object?>
              ? schema
              : <String, Object?>{'type': 'object'},
          requiresApproval: true,
          execute: (final args) async {
            try {
              final response =
                  await rpc.request('tools/call', <String, Object?>{
                'name': remoteName,
                'arguments': args,
              });
              final text = _toolText(response['content']);
              return response['isError'] == true
                  ? ToolOutcome.error(text)
                  : ToolOutcome(content: text);
            } catch (error) {
              return ToolOutcome.error('Plugin ${manifest.id}: $error');
            }
          },
        ));
      }
    } catch (_) {
      await rpc.dispose();
      _rpc = null;
      rethrow;
    }
  }

  @override
  Future<void> unmount(final PluginContext context) async {
    final rpc = _rpc;
    _rpc = null;
    await rpc?.dispose();
  }

  static String _toolText(final Object? content) {
    if (content is! List) return content?.toString() ?? '';
    return content
        .map((final item) {
          if (item is Map<String, Object?>) {
            return (item['text'] ?? item['uri'] ?? '').toString();
          }
          return item.toString();
        })
        .where((final value) => value.isNotEmpty)
        .join('\n');
  }
}
