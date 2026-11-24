import 'dart:convert';
import 'dart:io';

import 'plugin_api.dart';
import 'mcp_http_client.dart';
import 'mcp_stdio_client.dart';
import 'mcp_command_parser.dart';
import 'plugin_runtime.dart';
import 'web_search_parser.dart';

/// Herramientas del núcleo, empaquetadas como plugins.
///
/// Los nombres replican el catálogo de dsh (`read`, `write`, `edit`, `glob`,
/// `grep`, `bash`, `terminal_*`, `todo_write`, `subagent`, `web_fetch`…), para
/// que un prompt escrito para dsh funcione aquí sin traducción.
///
/// Cada plugin declara solo las capacidades que usa: si pide `shell` y no la
/// declara, `context.services.shell` lanza [PluginCapabilityDenied].

/// Utilidad: esquema JSON de objeto con propiedades.
Map<String, Object?> _obj(
  final Map<String, Object?> properties, {
  final List<String> required = const <String>[],
}) =>
    <String, Object?>{
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    };

Map<String, Object?> _str(final String description) =>
    <String, Object?>{'type': 'string', 'description': description};

Map<String, Object?> _int(final String description) =>
    <String, Object?>{'type': 'integer', 'description': description};

// ---------------------------------------------------------------------------
// core-fs: read, write, glob, grep
// ---------------------------------------------------------------------------

class _FsPlugin extends ChronoxPlugin {
  _FsPlugin({
    required this.id,
    required this.name,
    required this.description,
    required final List<PluginTool> Function(PluginContext) tools,
  }) : _buildTools = tools;

  final String id;
  final String name;
  final String description;
  final List<PluginTool> Function(PluginContext) _buildTools;

  @override
  Future<void> mount(final PluginContext context) async {
    for (final tool in _buildTools(context)) {
      context.provideTool(tool);
    }
  }
}

ChronoxPlugin fsPlugin() => _FsPlugin(
      id: 'core-fs',
      name: 'Sistema de archivos',
      description: 'Lectura, escritura, búsqueda y listado en /workspace.',
      tools: (final context) => <PluginTool>[
        PluginTool(
          name: 'read',
          description:
              'Lee un fichero de texto. Devuelve el contenido con números de línea. '
              'Usa `offset` y `limit` para ficheros grandes en lugar de leerlo todo.',
          requiresApproval: false,
          inputSchema: _obj(<String, Object?>{
            'path': _str('Ruta absoluta o relativa a /workspace.'),
            'offset': _int('Primera línea a devolver (1-based).'),
            'limit': _int('Número máximo de líneas.'),
          }, required: <String>[
            'path'
          ]),
          execute: (final args) async {
            final path = args['path']! as String;
            final offset = (args['offset'] as int?) ?? 1;
            final limit = (args['limit'] as int?) ?? 2000;

            final lines = await context.services.fileSystem.readFile(path);
            final all = lines.split('\n');
            final start = (offset - 1).clamp(0, all.length);
            final end = (start + limit).clamp(0, all.length);
            final slice = all.sublist(start, end);

            final numbered = <String>[];
            for (var i = 0; i < slice.length; i++) {
              final number = start + i + 1;
              numbered.add('${number.toString().padLeft(6)}\t${slice[i]}');
            }

            final truncated = end < all.length;
            return ToolOutcome(
              content: truncated
                  ? '${numbered.join('\n')}\n\n[truncado: quedan '
                      '${all.length - end} líneas. Usa offset=${end + 1}]'
                  : numbered.join('\n'),
              metadata: <String, Object?>{
                'lines': all.length,
                'truncated': truncated
              },
            );
          },
        ),
        PluginTool(
          name: 'write',
          description:
              'Crea o sobrescribe un fichero. Si el fichero existe, se muestra un '
              'diff antes de aplicar el cambio.',
          inputSchema: _obj(<String, Object?>{
            'path': _str('Ruta del fichero.'),
            'content': _str('Contenido completo.'),
          }, required: <String>[
            'path',
            'content'
          ]),
          execute: (final args) async {
            final path = args['path']! as String;
            final content = args['content']! as String;
            await context.services.fileSystem.writeFile(path, content);
            final lines = content.split('\n').length;
            return ToolOutcome(
              content:
                  'Escrito $path ($lines líneas, ${content.length} caracteres).',
              metadata: <String, Object?>{'path': path, 'lines': lines},
            );
          },
        ),
        PluginTool(
          name: 'glob',
          description:
              'Encuentra ficheros por patrón (`**/*.dart`, `lib/**/*.ts`). '
              'Más rápido que `find` para localizar archivos por nombre.',
          requiresApproval: false,
          inputSchema: _obj(<String, Object?>{
            'pattern': _str('Patrón glob.'),
            'path': _str('Directorio base (por defecto /workspace).'),
          }, required: <String>[
            'pattern'
          ]),
          execute: (final args) async {
            final matches = await context.services.fileSystem.glob(
              args['pattern']! as String,
            );
            if (matches.isEmpty) {
              return const ToolOutcome(content: 'Sin coincidencias.');
            }
            return ToolOutcome(
              content: matches.take(500).join('\n'),
              metadata: <String, Object?>{'count': matches.length},
            );
          },
        ),
        PluginTool(
          name: 'grep',
          description:
              'Busca un patrón en el contenido de los ficheros. Devuelve '
              '`ruta:línea:texto`.',
          requiresApproval: false,
          inputSchema: _obj(<String, Object?>{
            'pattern': _str('Expresión regular.'),
            'path': _str('Directorio o fichero donde buscar.'),
          }, required: <String>[
            'pattern'
          ]),
          execute: (final args) async {
            final results = await context.services.fileSystem.grep(
              args['pattern']! as String,
              path: args['path'] as String?,
            );
            if (results.isEmpty) {
              return const ToolOutcome(content: 'Sin coincidencias.');
            }
            return ToolOutcome(
              content: results.take(200).join('\n'),
              metadata: <String, Object?>{'count': results.length},
            );
          },
        ),
      ],
    );

// ---------------------------------------------------------------------------
// core-search: política de búsqueda
// ---------------------------------------------------------------------------

/// No registra herramientas: ajusta cómo se comportan `glob` y `grep`.
///
/// Es el ejemplo más claro de "todo es un plugin": una capacidad puede ser una
/// *política* y no solo código ejecutable. Al desmontarlo, los límites vuelven a
/// su valor por defecto (composabilidad temporal).
class _SearchPolicyPlugin extends ChronoxPlugin {
  _SearchPolicyPlugin();

  /// Carpetas que nunca interesan al modelo y que quemarían contexto.
  static const List<String> defaultExcludes = <String>[
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    '__pycache__',
    '.venv',
  ];

  @override
  Future<void> mount(final PluginContext context) async {
    // Publica la política como un skill legible por el modelo: así los límites
    // son visibles en el prompt (y no un estado oculto), y desmontar el plugin
    // los retira del contexto.
    context.provideSkill(
      PluginSkill(
        id: 'search-policy',
        name: 'Política de búsqueda',
        instructions: 'Al buscar en el proyecto, ignora estas carpetas: '
            '${defaultExcludes.join(", ")}. '
            'Limita los resultados a 200 coincidencias y pide un patrón más '
            'específico si hay más.',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// core-shell: bash
// ---------------------------------------------------------------------------

class _ShellPlugin extends ChronoxPlugin {
  _ShellPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'bash',
        description:
            'Ejecuta un comando en el contenedor Linux (Debian) y devuelve su '
            'salida y el código de salida. El directorio por defecto es '
            '/workspace. No uses comandos interactivos: para eso está '
            '`terminal_open`.',
        inputSchema: _obj(<String, Object?>{
          'command': _str('Comando a ejecutar.'),
          'workdir': _str('Directorio de trabajo.'),
          'timeout_ms':
              _int('Tiempo máximo en milisegundos (por defecto 120000).'),
        }, required: <String>[
          'command'
        ]),
        execute: (final args) async {
          final timeoutMs = (args['timeout_ms'] as int?) ?? 120000;
          final result = await context.services.shell.run(
            args['command']! as String,
            workingDirectory: args['workdir'] as String?,
            timeout: Duration(milliseconds: timeoutMs.clamp(1000, 600000)),
          );
          final output = result.output;
          return ToolOutcome(
            content: output.isEmpty ? '(sin salida)' : output,
            isError: !result.isSuccess,
            metadata: <String, Object?>{'exitCode': result.exitCode},
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// core-terminal: terminal_open / terminal_send / terminal_read / terminal_close
// ---------------------------------------------------------------------------

class _TerminalPlugin extends ChronoxPlugin {
  _TerminalPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'terminal_open',
        description:
            'Abre una terminal persistente. Útil para procesos interactivos o '
            'de larga duración (dev servers, REPLs). Devuelve un id.',
        requiresApproval: false,
        inputSchema:
            _obj(<String, Object?>{'title': _str('Etiqueta visible.')}),
        execute: (final args) async {
          final id = await context.services.terminals.open(
            title: args['title'] as String?,
          );
          return ToolOutcome(
            content: 'Terminal abierta con id="$id".',
            metadata: <String, Object?>{'terminalId': id},
          );
        },
      ),
    );
    context.provideTool(
      PluginTool(
        name: 'terminal_send',
        description:
            'Escribe en una terminal. Añade \\n al final si hace falta.',
        inputSchema: _obj(<String, Object?>{
          'terminal_id': _str('Id devuelto por terminal_open.'),
          'input': _str('Texto a escribir.'),
        }, required: <String>[
          'terminal_id',
          'input'
        ]),
        execute: (final args) async {
          await context.services.terminals.send(
            args['terminal_id']! as String,
            args['input']! as String,
          );
          return const ToolOutcome(content: 'Enviado.');
        },
      ),
    );
    context.provideTool(
      PluginTool(
        name: 'terminal_read',
        description: 'Lee la salida acumulada de una terminal.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'terminal_id': _str('Id de la terminal.'),
        }, required: <String>[
          'terminal_id'
        ]),
        execute: (final args) async {
          final output = await context.services.terminals.read(
            args['terminal_id']! as String,
          );
          return ToolOutcome(
            content: output.isEmpty ? '(sin salida todavía)' : output,
          );
        },
      ),
    );
    context.provideTool(
      PluginTool(
        name: 'terminal_list',
        description: 'Lista las terminales abiertas y su estado.',
        requiresApproval: false,
        inputSchema: _obj(const <String, Object?>{}),
        execute: (final args) async {
          final terminals = await context.services.terminals.list();
          if (terminals.isEmpty) {
            return const ToolOutcome(content: 'No hay terminales abiertas.');
          }
          final lines = <String>[];
          for (final terminal in terminals) {
            final state = terminal.isAlive ? 'activa' : 'cerrada';
            lines.add(
              '${terminal.id} · ${terminal.title} · $state · '
              '${terminal.bytesProduced} bytes',
            );
          }
          return ToolOutcome(content: lines.join('\n'));
        },
      ),
    );
    context.provideTool(
      PluginTool(
        name: 'terminal_close',
        description: 'Cierra una terminal y mata sus procesos.',
        inputSchema: _obj(<String, Object?>{
          'terminal_id': _str('Id de la terminal.'),
        }, required: <String>[
          'terminal_id'
        ]),
        execute: (final args) async {
          await context.services.terminals
              .close(args['terminal_id']! as String);
          return const ToolOutcome(content: 'Terminal cerrada.');
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// core-editing: edit (str_replace) y apply_patch
// ---------------------------------------------------------------------------

class _EditingPlugin extends ChronoxPlugin {
  _EditingPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'edit',
        description:
            'Reemplaza un fragmento exacto de un fichero. `old_str` debe '
            'aparecer EXACTAMENTE una vez: incluye contexto suficiente para que '
            'sea único. Es la herramienta preferida para cambios quirúrgicos.',
        inputSchema: _obj(<String, Object?>{
          'path': _str('Ruta del fichero.'),
          'old_str': _str('Texto exacto a reemplazar (único en el fichero).'),
          'new_str': _str('Texto nuevo. Vacío para borrar.'),
        }, required: <String>[
          'path',
          'old_str',
          'new_str'
        ]),
        execute: (final args) async {
          final path = args['path']! as String;
          final oldStr = args['old_str']! as String;
          final newStr = (args['new_str'] as String?) ?? '';

          final content = await context.services.fileSystem.readFile(path);
          final occurrences =
              oldStr.isEmpty ? 0 : oldStr.allMatches(content).length;

          if (occurrences == 0) {
            return ToolOutcome.error(
              'No se encontró `old_str` en $path. Revisa el contenido con '
              '`read` antes de editar.',
            );
          }
          if (occurrences > 1) {
            return ToolOutcome.error(
              '`old_str` aparece $occurrences veces en $path. Incluye más '
              'contexto para que sea único.',
            );
          }

          final updated = content.replaceFirst(oldStr, newStr);
          await context.services.fileSystem.writeFile(path, updated);
          return ToolOutcome(
            content:
                'Editado $path (−${oldStr.length} +${newStr.length} bytes).',
            metadata: <String, Object?>{'path': path},
          );
        },
      ),
    );
    context.provideTool(
      PluginTool(
        name: 'apply_patch',
        description:
            'Aplica un diff unificado a uno o varios ficheros. Útil para '
            'cambios grandes o múltiples a la vez.',
        inputSchema: _obj(<String, Object?>{
          'patch': _str('Diff en formato unificado.'),
        }, required: <String>[
          'patch'
        ]),
        execute: (final args) async {
          // Se delega en `patch` del contenedor: reimplementar un parser de
          // diffs en Dart sería frágil y el contenedor ya lo tiene.
          final stamp = DateTime.now().microsecondsSinceEpoch;
          final tmp = '/tmp/chronox-patch-$stamp.diff';
          await context.services.fileSystem
              .writeFile(tmp, args['patch']! as String);
          final result = await context.services.shell.run(
            'patch -p1 --forward --input="$tmp" && rm -f "$tmp"',
          );
          return ToolOutcome(
            content: result.output.isEmpty ? 'Patch aplicado.' : result.output,
            isError: !result.isSuccess,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// core-todo y core-plan
// ---------------------------------------------------------------------------

class _TodoPlugin extends ChronoxPlugin {
  _TodoPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    final items = <Map<String, Object?>>[];
    context.provideTool(
      PluginTool(
        name: 'todo_write',
        description:
            'Mantén la lista de tareas de la sesión. Úsala para tareas de más '
            'de 3 pasos: el usuario ve el progreso en tiempo real. Reemplaza la '
            'lista completa cada vez.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'todos': <String, Object?>{
            'type': 'array',
            'description': 'Lista completa de tareas.',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'content': _str('Descripción de la tarea.'),
                'status': <String, Object?>{
                  'type': 'string',
                  'enum': <String>['pending', 'in_progress', 'completed'],
                },
              },
              'required': <String>['content', 'status'],
            },
          },
        }, required: <String>[
          'todos'
        ]),
        execute: (final args) async {
          items
            ..clear()
            ..addAll(
              ((args['todos'] as List<Object?>?) ?? <Object?>[])
                  .whereType<Map<String, Object?>>(),
            );
          final done =
              items.where((final t) => t['status'] == 'completed').length;
          return ToolOutcome(
            content: 'Lista actualizada: $done/${items.length} completadas.',
            metadata: <String, Object?>{'todos': items},
          );
        },
      ),
    );
  }
}

class _PlanPlugin extends ChronoxPlugin {
  _PlanPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'exit_plan_mode',
        description:
            'Presenta un plan al usuario y pide aprobación antes de ejecutar. '
            'Úsalo en tareas grandes o destructivas: en lugar de actuar, '
            'describe los pasos y espera.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'plan': _str('Plan en Markdown, con pasos numerados.'),
        }, required: <String>[
          'plan'
        ]),
        execute: (final args) async => ToolOutcome(
            content: 'Plan presentado al usuario para aprobación:\n\n'
                '${args['plan']}'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// core-search: web_fetch
// ---------------------------------------------------------------------------

class _WebPlugin extends ChronoxPlugin {
  _WebPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'web_search',
        description:
            'Busca en la web y devuelve títulos, URLs y extractos breves. '
            'Úsala para información actual o cuando necesites fuentes.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'query': _str('Consulta de búsqueda.'),
          'limit': <String, Object?>{
            'type': 'integer',
            'description': 'Cantidad de resultados (1 a 8, por defecto 5).',
          },
        }, required: <String>[
          'query'
        ]),
        execute: (final args) async {
          final query = (args['query'] ?? '').toString().trim();
          if (query.isEmpty)
            return ToolOutcome.error('La consulta está vacía.');
          final requested = (args['limit'] as num?)?.toInt() ?? 5;
          final limit = requested.clamp(1, 8).toInt();
          final uri =
              Uri.https('html.duckduckgo.com', '/html/', <String, String>{
            'q': query,
          });
          final response = await context.services.network.get(
            uri,
            headers: const <String, String>{
              'User-Agent': 'Mozilla/5.0 ChronoxAI/0.2',
              'Accept': 'text/html',
            },
          );
          if (!response.isSuccess) {
            return ToolOutcome.error(
                'Búsqueda web: HTTP ${response.statusCode}.');
          }
          final results = WebSearchParser.parse(response.body, limit: limit);
          if (results.isEmpty) {
            return const ToolOutcome(content: 'No se encontraron resultados.');
          }
          return ToolOutcome(
            content: results
                .map((final result) =>
                    '${result.title} · ${result.url}\n${result.snippet}')
                .join('\n\n'),
          );
        },
      ),
    );

    context.provideTool(
      PluginTool(
        name: 'web_fetch',
        description:
            'Descarga una URL y devuelve el texto. Sin ejecutar JavaScript.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'url': _str('URL a descargar.'),
        }, required: <String>[
          'url'
        ]),
        execute: (final args) async {
          final response = await context.services.network.get(
            Uri.parse(args['url']! as String),
          );
          if (!response.isSuccess) {
            return ToolOutcome.error(
              'HTTP ${response.statusCode} al descargar ${args['url']}.',
            );
          }
          final text = _stripHtml(response.body);
          return ToolOutcome(
            content: text.length > 20000
                ? '${text.substring(0, 20000)}\n\n[truncado]'
                : text,
          );
        },
      ),
    );
  }

  /// Elimina etiquetas y colapsa espacios: el modelo no necesita el HTML.
  static String _stripHtml(final String html) {
    final withoutScripts = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>'), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>'), ' ');
    final withoutTags = withoutScripts.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return withoutTags
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}

// ---------------------------------------------------------------------------
// core-mcp
// ---------------------------------------------------------------------------

class _McpPlugin extends ChronoxPlugin {
  _McpPlugin(this.serverUrl, this.startMcpProcess);

  final String? serverUrl;
  final Future<Process> Function(List<String> command)? startMcpProcess;
  final List<McpStdioClient> _stdioClients = <McpStdioClient>[];

  @override
  Future<void> mount(final PluginContext context) async {
    final servers = (serverUrl ?? '')
        .split('\n')
        .map((final row) => row.trim())
        .toList(growable: false);
    try {
      for (var index = 0; index < servers.length; index++) {
        final server = servers[index];
        // A leading # disables just this saved server without removing it.
        if (server.isEmpty || server.startsWith('#')) continue;
        await _mountServer(context, server, index, servers.length);
      }
    } catch (_) {
      await _disposeStdioClients();
      rethrow;
    }
  }

  Future<void> _mountServer(
    final PluginContext context,
    final String configured,
    final int serverIndex,
    final int serverCount,
  ) async {
    late final Future<List<Map<String, Object?>>> Function() listTools;
    late final Future<String> Function(String, Map<String, Object?>) callTool;
    McpStdioClient? stdioClient;
    if (configured.startsWith('stdio:')) {
      final command =
          parseMcpStdioCommand(configured.substring('stdio:'.length));
      final startProcess = startMcpProcess;
      if (command.isEmpty || command.first.isEmpty || startProcess == null) {
        throw const FormatException(
            'Configura stdio:npx --yes paquete-mcp y un runtime Linux listo.');
      }
      stdioClient = McpStdioClient(await startProcess(command));
      _stdioClients.add(stdioClient);
      listTools = stdioClient.listTools;
      callTool = stdioClient.callTool;
    } else {
      final endpoint = Uri.tryParse(configured);
      if (endpoint == null ||
          (endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
          endpoint.host.isEmpty) {
        throw const FormatException(
            'Configura una URL MCP HTTP(S) o stdio:<comando>.');
      }
      final client =
          McpHttpClient(network: context.services.network, endpoint: endpoint);
      listTools = client.listTools;
      callTool = client.callTool;
    }

    late final List<Map<String, Object?>> tools;
    try {
      tools = await listTools();
    } catch (_) {
      if (stdioClient != null) {
        _stdioClients.remove(stdioClient);
        await stdioClient.dispose();
      }
      rethrow;
    }
    for (final remote in tools) {
      final remoteName = (remote['name'] as String?)?.trim() ?? '';
      if (remoteName.isEmpty) continue;
      final normalized = remoteName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final safeName = serverCount == 1
          ? 'mcp_$normalized'
          : 'mcp_${serverIndex + 1}_$normalized';
      final schema = remote['inputSchema'];
      final inputSchema = schema is Map<String, Object?>
          ? schema
          : <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{}
            };
      final description =
          (remote['description'] as String?) ?? 'MCP: $remoteName';
      context.provideTool(PluginTool(
        name: safeName,
        description: description,
        inputSchema: inputSchema,
        requiresApproval: true,
        execute: (final args) async {
          try {
            return ToolOutcome(content: await callTool(remoteName, args));
          } catch (error) {
            return ToolOutcome.error(
                'Error en la herramienta MCP $remoteName: $error');
          }
        },
      ));
    }
  }

  @override
  Future<void> unmount() => _disposeStdioClients();

  Future<void> _disposeStdioClients() async {
    final clients = _stdioClients.toList();
    _stdioClients.clear();
    for (final client in clients) {
      await client.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// core-subagent
// ---------------------------------------------------------------------------

/// Ejecuta un subagente con su propio ámbito.
///
/// El runner se inyecta desde el `AgentLoop` real (para evitar la dependencia
/// circular); si no está disponible, la herramienta informa en vez de fallar
/// de forma opaca.
class _SubagentPlugin extends ChronoxPlugin {
  _SubagentPlugin(this.runner, this.parallelRunner);

  final Future<String> Function(String prompt, String? description)? runner;
  final Future<List<String>> Function(List<Map<String, String>> tasks)?
      parallelRunner;

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'subagent',
        description:
            'Delega una subtarea acotada a un subagente con contexto limpio. '
            'Úsalo para exploraciones amplias (buscar en todo el repo) que no '
            'deben ensuciar tu contexto principal.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'prompt': _str('Tarea concreta y autocontenida.'),
          'description': _str('Descripción corta, para la UI.'),
        }, required: <String>[
          'prompt'
        ]),
        execute: (final args) async {
          final run = runner;
          if (run == null) {
            return const ToolOutcome.error(
              'El subagente no está disponible en este runtime.',
            );
          }
          final result = await run(
            args['prompt']! as String,
            args['description'] as String?,
          );
          return ToolOutcome(content: result);
        },
      ),
    );
    context.provideTool(
      PluginTool(
        name: 'subagents',
        description:
            'Ejecuta en paralelo hasta cuatro subtareas independientes '
            'con subagentes read-only y devuelve cada resultado etiquetado.',
        requiresApproval: false,
        inputSchema: _obj(<String, Object?>{
          'tasks': <String, Object?>{
            'type': 'array',
            'description': 'Lista de tareas {prompt, description}. Máximo 4.',
            'items': <String, Object?>{'type': 'object'},
          },
        }, required: <String>[
          'tasks'
        ]),
        execute: (final args) async {
          final run = parallelRunner;
          if (run == null) {
            return const ToolOutcome.error(
                'Los subagentes paralelos no están disponibles.');
          }
          final rawTasks = args['tasks'] as List<Object?>? ?? const <Object?>[];
          if (rawTasks.isEmpty || rawTasks.length > 4) {
            return const ToolOutcome.error('Indica entre 1 y 4 tareas.');
          }
          final tasks = rawTasks
              .whereType<Map<String, Object?>>()
              .map((final task) => <String, String>{
                    'prompt': (task['prompt'] ?? '').toString(),
                    if (task['description'] != null)
                      'description': task['description'].toString(),
                  })
              .toList();
          if (tasks.any((final task) => task['prompt']!.trim().isEmpty)) {
            return const ToolOutcome.error(
                'Cada tarea necesita un prompt no vacío.');
          }
          final results = await run(tasks);
          return ToolOutcome(
            content: results.indexed
                .map((final entry) =>
                    '### Subagente ${entry.$1 + 1}\n${entry.$2}')
                .join('\n\n'),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// code-mode: run_code (PTC)
// ---------------------------------------------------------------------------

class _CodeModePlugin extends ChronoxPlugin {
  _CodeModePlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'run_code',
        description:
            'Ejecuta un programa Python dentro del contenedor. En lugar de '
            'encadenar muchas llamadas a herramientas, escribe un programa que '
            'haga todo el trabajo y devuelva un resumen. Tienes acceso a '
            '/workspace y a los comandos del sistema (subprocess).',
        inputSchema: _obj(<String, Object?>{
          'code': _str('Código Python a ejecutar.'),
          'timeout_ms': _int('Tiempo máximo (por defecto 300000).'),
        }, required: <String>[
          'code'
        ]),
        execute: (final args) async {
          final script = args['code']! as String;
          final timeoutMs = (args['timeout_ms'] as int?) ?? 300000;
          final path =
              '/tmp/chronox-run-${DateTime.now().microsecondsSinceEpoch}.py';
          await context.services.fileSystem.writeFile(path, script);

          final result = await context.services.shell.run(
            // Comillas simples de shell: el `$?` no lo toca Dart ni el shell exterior.
            "cd /workspace && python3 '$path'; rc=\$?; rm -f '$path'; exit \$rc",
            timeout: Duration(milliseconds: timeoutMs.clamp(5000, 900000)),
          );

          return ToolOutcome(
            content: result.output.isEmpty
                ? 'El programa terminó sin salida.'
                : result.output,
            isError: !result.isSuccess,
            metadata: <String, Object?>{'exitCode': result.exitCode},
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// creator: cordis_inspect y plugin_manager
// ---------------------------------------------------------------------------

class _CreatorInspectPlugin extends ChronoxPlugin {
  _CreatorInspectPlugin(this.hostProvider);

  /// Se inyecta en tiempo de montaje para no acoplar el plugin al host.
  final Map<String, Object?> Function()? hostProvider;

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'cordis_inspect',
        description: 'Inspecciona el runtime: plugins montados, herramientas '
            'registradas, skills, modos y pantallas.',
        requiresApproval: false,
        inputSchema: _obj(const <String, Object?>{}),
        execute: (final args) async {
          final snapshot = hostProvider?.call() ?? <String, Object?>{};
          return ToolOutcome(
            content: const JsonEncoder.withIndent('  ').convert(snapshot),
          );
        },
      ),
    );
  }
}

class _PluginManagerPlugin extends ChronoxPlugin {
  _PluginManagerPlugin({required this.host, required this.lister});

  final PluginHost? host;

  /// Lista de manifiestos registrados, con su estado.
  final List<Map<String, Object?>> Function()? lister;

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'plugin_manager',
        description:
            'Gestiona plugins: listar, montar y desmontar. Al montar un plugin '
            'aparecen sus herramientas y, si aporta una pantalla, su entrada en '
            'la navegación.',
        inputSchema: _obj(<String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['list', 'mount', 'unmount'],
          },
          'plugin_id': _str('Id del plugin (para mount/unmount).'),
        }, required: <String>[
          'action'
        ]),
        execute: (final args) async {
          final action = args['action']! as String;
          final pluginId = args['plugin_id'] as String?;
          final target = host;

          switch (action) {
            case 'list':
              final items = lister?.call() ?? <Map<String, Object?>>[];
              return ToolOutcome(
                content: const JsonEncoder.withIndent('  ').convert(items),
              );
            case 'mount':
              if (pluginId == null) {
                return const ToolOutcome.error(
                    'Falta `plugin_id` para montar.');
              }
              if (target == null) {
                return const ToolOutcome.error(
                    'El host de plugins no está disponible.');
              }
              final ok = await target.mount(pluginId);
              return ok
                  ? ToolOutcome(content: 'Plugin "$pluginId" montado.')
                  : ToolOutcome.error(
                      'No se pudo montar "$pluginId": '
                      '${target.plugins.firstWhere((final p) => p.manifest.id == pluginId, orElse: () => target.plugins.first).error ?? "error desconocido"}',
                    );
            case 'unmount':
              if (pluginId == null) {
                return const ToolOutcome.error(
                    'Falta `plugin_id` para desmontar.');
              }
              if (target == null) {
                return const ToolOutcome.error(
                    'El host de plugins no está disponible.');
              }
              await target.unmount(pluginId);
              return ToolOutcome(content: 'Plugin "$pluginId" desmontado.');
            default:
              return ToolOutcome.error('Acción desconocida: $action');
          }
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Modo Minimal: solo dos herramientas, sin adornos
// ---------------------------------------------------------------------------

class _BaseShellPlugin extends ChronoxPlugin {
  _BaseShellPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'bash',
        description:
            'Ejecuta un comando persistente en el shell del contenedor.',
        inputSchema: _obj(<String, Object?>{
          'command': _str('Comando.'),
        }, required: <String>[
          'command'
        ]),
        execute: (final args) async {
          final result =
              await context.services.shell.run(args['command']! as String);
          return ToolOutcome(
            content: result.output,
            isError: !result.isSuccess,
          );
        },
      ),
    );
  }
}

class _BaseEditorPlugin extends ChronoxPlugin {
  _BaseEditorPlugin();

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(
      PluginTool(
        name: 'str_replace_editor',
        description:
            'Editor de reemplazo exacto: sustituye `old_str` por `new_str` en '
            'un fichero.',
        inputSchema: _obj(<String, Object?>{
          'path': _str('Fichero.'),
          'old_str': _str('Texto a reemplazar.'),
          'new_str': _str('Texto nuevo.'),
        }, required: <String>[
          'path',
          'old_str',
          'new_str'
        ]),
        execute: (final args) async {
          final path = args['path']! as String;
          final content = await context.services.fileSystem.readFile(path);
          final oldStr = args['old_str']! as String;
          if (!content.contains(oldStr)) {
            return ToolOutcome.error('`old_str` no se encontró en $path.');
          }
          await context.services.fileSystem.writeFile(
            path,
            content.replaceFirst(oldStr, (args['new_str'] as String?) ?? ''),
          );
          return const ToolOutcome(content: 'Editado.');
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Catálogo: qué plugins existen y con qué manifest
// ---------------------------------------------------------------------------

/// Definición de un plugin integrado: manifest + fábrica.
class BuiltinPlugin {
  const BuiltinPlugin({
    required this.manifest,
    required this.create,
    this.defaultEnabled = true,
  });

  final PluginManifest manifest;
  final ChronoxPlugin Function() create;
  final bool defaultEnabled;
}

/// Catálogo de los plugins que viajan con la app.
///
/// `create` se llama al registrar, y el host decide si se monta. Los plugins que
/// necesitan colaboradores del host (subagente, inspectores) se construyen con
/// argumentos, de ahí que `create` sea una función y no una constante.
List<BuiltinPlugin> builtinPlugins({
  Future<String> Function(String, String?)? subagentRunner,
  Future<List<String>> Function(List<Map<String, String>>)?
      parallelSubagentRunner,
  Map<String, Object?> Function()? inspectProvider,
  PluginHost? host,
  List<Map<String, Object?>> Function()? pluginLister,
  String? mcpServerUrl,
  Future<Process> Function(List<String>)? startMcpProcess,
}) {
  PluginManifest manifest({
    required final String id,
    required final String name,
    required final String description,
    required final PluginKind kind,
    final List<PluginCapability> capabilities = const <PluginCapability>[],
    final List<String> requires = const <String>[],
    final String? icon,
  }) =>
      PluginManifest(
        id: id,
        name: name,
        version: '1.0.0',
        kind: kind,
        description: description,
        author: 'Chronox AI',
        capabilities: capabilities,
        requires: requires,
        icon: icon,
        enabledByDefault: true,
      );

  const fsCaps = <PluginCapability>[PluginCapability.fileSystem];

  return <BuiltinPlugin>[
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-fs',
        name: 'Sistema de archivos',
        description: 'read, write, glob, grep',
        kind: PluginKind.tool,
        capabilities: fsCaps,
        icon: 'folder',
      ),
      create: fsPlugin,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-shell',
        name: 'Shell',
        description: 'bash en el contenedor',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[PluginCapability.shell],
        requires: <String>['core-fs'],
        icon: 'terminal',
      ),
      create: _ShellPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-terminal',
        name: 'Terminales',
        description: 'terminal_open, send, read, list, close',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[PluginCapability.terminals],
        requires: <String>['core-shell'],
        icon: 'tab',
      ),
      create: _TerminalPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-editing',
        name: 'Edición',
        description: 'edit (str_replace), apply_patch',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[
          PluginCapability.fileSystem,
          PluginCapability.shell,
        ],
        requires: <String>['core-fs'],
        icon: 'edit',
      ),
      create: _EditingPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-todo',
        name: 'Tareas',
        description: 'todo_write',
        kind: PluginKind.tool,
        icon: 'checklist',
      ),
      create: _TodoPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-plan',
        name: 'Planificación',
        description: 'exit_plan_mode',
        kind: PluginKind.tool,
        icon: 'map',
      ),
      create: _PlanPlugin.new,
    ),
    // `core-search` no aporta herramientas nuevas: declara la *política* de
    // búsqueda (límites, exclusiones) que `core-fs` consulta. Separarlo permite
    // desactivar la búsqueda sin quitar la lectura de archivos, que es lo que
    // dsh consigue con ctx.tools + ámbito.
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-search',
        name: 'Búsqueda',
        description: 'Política de búsqueda: límites y exclusiones',
        kind: PluginKind.tool,
        capabilities: fsCaps,
        requires: <String>['core-fs'],
        icon: 'search',
      ),
      create: _SearchPolicyPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-web',
        name: 'Web',
        description: 'web_fetch',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[PluginCapability.network],
        icon: 'globe',
      ),
      create: _WebPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-mcp',
        name: 'MCP remoto',
        description: 'Herramientas de servidor MCP por Streamable HTTP',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[PluginCapability.network],
        icon: 'hub',
      ),
      create: () => _McpPlugin(mcpServerUrl, startMcpProcess),
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'core-subagent',
        name: 'Subagentes',
        description: 'subagent',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[PluginCapability.llm],
        icon: 'fork',
      ),
      create: () => _SubagentPlugin(subagentRunner, parallelSubagentRunner),
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'code-mode',
        name: 'Code Mode (PTC)',
        description: 'run_code: orquesta varias tools en un programa',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[
          PluginCapability.shell,
          PluginCapability.fileSystem,
        ],
        requires: <String>['core-shell'],
        icon: 'integration_instructions',
      ),
      create: _CodeModePlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'creator-inspect',
        name: 'Inspección del runtime',
        description: 'cordis_inspect',
        kind: PluginKind.tool,
        icon: 'visibility',
      ),
      create: () => _CreatorInspectPlugin(inspectProvider),
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'creator-plugin-manager',
        name: 'Gestor de plugins',
        description: 'plugin_manager',
        kind: PluginKind.tool,
        requires: <String>['creator-inspect'],
        icon: 'extension',
      ),
      create: () => _PluginManagerPlugin(host: host, lister: pluginLister),
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'base-shell',
        name: 'Shell mínimo',
        description: 'bash, sin dependencias (modo Minimal)',
        kind: PluginKind.tool,
        capabilities: const <PluginCapability>[PluginCapability.shell],
        icon: 'terminal',
      ),
      create: _BaseShellPlugin.new,
    ),
    BuiltinPlugin(
      manifest: manifest(
        id: 'base-editor',
        name: 'Editor mínimo',
        description: 'str_replace_editor (modo Minimal)',
        kind: PluginKind.tool,
        capabilities: fsCaps,
        icon: 'edit',
      ),
      create: _BaseEditorPlugin.new,
    ),
  ];
}
