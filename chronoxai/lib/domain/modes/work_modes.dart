import '../plugins/plugin_api.dart';

/// Los cuatro modos de trabajo de DeepSeek Harness, adaptados a Chronox AI.
///
/// Un modo **no es código**: es exclusivamente la lista de IDs de plugin que se
/// montan y el prefijo de system prompt. Esa es la prueba de que la arquitectura
/// es realmente "todo es un plugin": añadir un modo es añadir un dato.
abstract final class WorkModes {
  static const String standard = 'standard';
  static const String code = 'code';
  static const String minimal = 'minimal';
  static const String creator = 'creator';

  /// Plugins que componen cada modo, en orden de montaje.
  ///
  /// El orden importa: si un plugin depende de otro (`requires`), el host lo
  /// monta primero de todas formas, pero mantener el orden explícito hace el
  /// arranque determinista.
  static const Map<String, List<String>> pluginSets = <String, List<String>>{
    standard: <String>[
      'core-fs',
      'core-shell',
      'core-git',
      'core-project-check',
      'core-terminal',
      'core-search',
      'core-editing',
      'core-todo',
      'core-plan',
      'core-subagent',
      'core-web',
      'core-mcp',
    ],
    code: <String>[
      'core-fs',
      'core-shell',
      'core-git',
      'core-project-check',
      'core-terminal',
      'core-search',
      'core-editing',
      'core-todo',
      'core-plan',
      'core-subagent',
      'core-web',
      'core-mcp',
      'code-mode',
    ],
    minimal: <String>[
      'base-shell',
      'base-editor',
    ],
    creator: <String>[
      'core-fs',
      'core-shell',
      'core-git',
      'core-project-check',
      'core-terminal',
      'core-search',
      'core-editing',
      'core-todo',
      'core-plan',
      'core-subagent',
      'core-web',
      'core-mcp',
      'creator-inspect',
      'creator-plugin-manager',
    ],
  };

  static const List<PluginMode> all = <PluginMode>[
    PluginMode(
      id: standard,
      name: 'Standard',
      description:
          'Agente completo: edición, shell, Git, terminal, búsqueda web, '
          'planificación, plugins y subagentes. El modo por defecto.',
      pluginIds: <String>[
        'core-fs',
        'core-shell',
        'core-git',
        'core-project-check',
        'core-terminal',
        'core-search',
        'core-editing',
        'core-todo',
        'core-plan',
        'core-subagent',
        'core-web',
        'core-mcp',
      ],
      icon: 'auto_awesome',
    ),
    PluginMode(
      id: code,
      name: 'Code (PTC)',
      description:
          'Programmatic Tool Calling: el modelo escribe un programa Python que '
          'orquesta varias herramientas en una sola llamada, en lugar de '
          'encadenar round-trips.',
      pluginIds: <String>[
        'core-fs',
        'core-shell',
        'core-git',
        'core-project-check',
        'core-terminal',
        'core-search',
        'core-editing',
        'core-todo',
        'core-plan',
        'core-subagent',
        'core-web',
        'core-mcp',
        'code-mode',
      ],
      systemPromptPrefix:
          'Tienes acceso a la herramienta `run_code`. Cuando una tarea requiera '
          'varios pasos encadenados (buscar, leer, editar, verificar), prefiere '
          'escribir un único programa que los ejecute en orden, en lugar de '
          'llamar a cada herramienta por separado. El programa corre dentro del '
          'contenedor Linux con acceso a /workspace.',
      icon: 'code',
    ),
    PluginMode(
      id: minimal,
      name: 'Minimal',
      description:
          'Solo dos herramientas: shell persistente y editor de reemplazo. '
          'Útil para medir el modelo sin ayuda del harness.',
      pluginIds: <String>['base-shell', 'base-editor'],
      systemPromptPrefix:
          'Dispones únicamente de un shell y un editor. No hay herramientas de '
          'búsqueda, planificación ni subagentes. Resuelve la tarea con lo que '
          'tienes.',
      icon: 'minimize',
    ),
    PluginMode(
      id: creator,
      name: 'Creator',
      description: 'Standard más inspección del runtime: ver plugins montados, '
          'herramientas registradas y montar/desmontar en caliente.',
      pluginIds: <String>[
        'core-fs',
        'core-shell',
        'core-git',
        'core-project-check',
        'core-terminal',
        'core-search',
        'core-editing',
        'core-todo',
        'core-plan',
        'core-subagent',
        'core-web',
        'core-mcp',
        'creator-inspect',
        'creator-plugin-manager',
      ],
      systemPromptPrefix:
          'Estás en modo Creator. Puedes inspeccionar el runtime con '
          '`cordis_inspect` y gestionar plugins con `plugin_manager`. Cuando '
          'escribas un plugin nuevo, colócalo en el directorio de plugins de '
          'usuario y explica al usuario qué capacidades declara.',
      icon: 'extension',
    ),
  ];

  static PluginMode byId(final String id) => all.firstWhere(
        (final m) => m.id == id,
        orElse: () => all.first,
      );

  static List<String> pluginsFor(final String modeId) =>
      pluginSets[modeId] ?? pluginSets[standard]!;
}
