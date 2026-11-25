import '../agent/workspace_index.dart';
import 'plugin_api.dart';

/// Exposes bounded symbol/import/reference lookups over a session-local index.
class WorkspaceIndexPlugin extends ChronoxPlugin {
  @override
  Future<void> mount(final PluginContext context) async {
    final index = WorkspaceIndex(context.services.fileSystem);

    context.provideTool(
      PluginTool(
        name: 'workspace_symbols',
        description:
            'Busca declaraciones de clases, funciones, tipos y variables en el '
            'índice de código del workspace. Devuelve rutas y líneas. Los '
            'resultados son aproximados (regex), no una garantía del compilador.',
        requiresApproval: false,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'query': <String, Object?>{
              'type': 'string',
              'description': 'Fragmento del nombre; vacío devuelve símbolos iniciales.',
            },
            'kind': <String, Object?>{
              'type': 'string',
              'description': 'Filtra por clase, función, tipo u otra categoría.',
            },
            'limit': <String, Object?>{
              'type': 'integer',
              'description': 'Máximo 100 resultados (por defecto 50).',
            },
          },
          'additionalProperties': false,
        },
        execute: (final args) async {
          await index.refresh();
          final query = (args['query'] as String?) ?? '';
          final kind = (args['kind'] as String?)?.toLowerCase();
          final limit = ((args['limit'] as int?) ?? 50).clamp(1, 100).toInt();
          final matches = index
              .symbols(query: query, limit: 100)
              .where((final item) => kind == null || item.kind == kind)
              .take(limit)
              .toList();
          final content = matches.isEmpty
              ? 'No se encontraron símbolos con esa consulta.'
              : matches
                  .map((final item) =>
                      '${item.path}:${item.line} ${item.kind} ${item.name} '
                      '[${item.language}, aproximado]')
                  .join('\n');
          return ToolOutcome(
            content: content,
            metadata: _indexMetadata(index, matches.length),
          );
        },
      ),
    );

    context.provideTool(
      PluginTool(
        name: 'workspace_imports',
        description:
            'Lista imports y módulos importados con archivo y línea. El índice '
            'refresca fuentes modificadas antes de cada consulta.',
        requiresApproval: false,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'query': <String, Object?>{
              'type': 'string',
              'description': 'Fragmento de ruta/módulo importado.',
            },
            'limit': <String, Object?>{
              'type': 'integer',
              'description': 'Máximo 100 resultados.',
            },
          },
          'additionalProperties': false,
        },
        execute: (final args) async {
          await index.refresh();
          final matches = index.imports(
            query: (args['query'] as String?) ?? '',
            limit: ((args['limit'] as int?) ?? 50).clamp(1, 100).toInt(),
          );
          return ToolOutcome(
            content: matches.isEmpty
                ? 'No se encontraron imports.'
                : matches
                    .map((final item) =>
                        '${item.path}:${item.line} import ${item.source} '
                        '[${item.language}, aproximado]')
                    .join('\n'),
            metadata: _indexMetadata(index, matches.length),
          );
        },
      ),
    );

    context.provideTool(
      PluginTool(
        name: 'workspace_references',
        description:
            'Busca referencias textuales exactas de un identificador, sin '
            'confundirlo con identificadores que solo comparten prefijo. '
            'Devuelve archivo, rango de línea/columna y extracto.',
        requiresApproval: false,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'symbol': <String, Object?>{
              'type': 'string',
              'description': 'Identificador completo (letras, números, _ o $).',
            },
            'limit': <String, Object?>{
              'type': 'integer',
              'description': 'Máximo 100 coincidencias.',
            },
          },
          'required': <String>['symbol'],
          'additionalProperties': false,
        },
        execute: (final args) async {
          await index.refresh();
          final symbol = args['symbol']! as String;
          final matches = index.references(
            symbol,
            limit: ((args['limit'] as int?) ?? 50).clamp(1, 100).toInt(),
          );
          return ToolOutcome(
            content: matches.isEmpty
                ? 'No se encontraron referencias exactas de $symbol.'
                : matches
                    .map((final item) =>
                        '${item.path}:${item.line}:${item.column}-'
                        '${item.endColumn} ${item.excerpt}')
                    .join('\n'),
            metadata: _indexMetadata(index, matches.length),
          );
        },
      ),
    );
  }

  static Map<String, Object?> _indexMetadata(
    final WorkspaceIndex index,
    final int resultCount,
  ) =>
      <String, Object?>{
        'indexedFiles': index.fileCount,
        'updatedFiles': index.updatedFiles,
        'skippedFiles': index.skippedFiles,
        'truncated': index.truncated,
        'cachedCharacters': index.cachedCharacters,
        'scanDurationMs': index.scanDurationMs,
        'resultCount': resultCount,
        'approximate': true,
      };
}
