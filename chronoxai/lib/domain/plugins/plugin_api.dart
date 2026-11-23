import 'dart:async';

import 'package:flutter/widgets.dart';

import '../agent/agent_events.dart';

/// Tipo de plugin. Determina qué puede registrar.
enum PluginKind {
  /// Aporta herramientas invocables por el modelo.
  tool,

  /// Aporta un pack de instrucciones reutilizable.
  skill,

  /// Aporta un modo de trabajo (un flavor: composición de otros plugins).
  mode,

  /// Aporta un adaptador de modelo.
  provider,

  /// Aporta **una pantalla propia** dentro de la app.
  surface,
}

/// Una capacidad del sistema que un plugin puede requerir.
///
/// El host solo entrega al plugin lo que declaró aquí: si un plugin pide
/// `fileSystem` pero no lo declara, recibirá un servicio que lanza
/// [PluginCapabilityDenied] en lugar de acceso silencioso.
enum PluginCapability {
  /// Leer y escribir dentro de `/workspace`.
  fileSystem,

  /// Ejecutar comandos en el contenedor Linux.
  shell,

  /// Abrir terminales persistentes.
  terminals,

  /// Llamar al modelo (para subagentes o clasificadores).
  llm,

  /// Leer el log de la sesión activa.
  session,

  /// Hacer peticiones HTTP salientes.
  network,
}

/// Error lanzado cuando un plugin usa una capacidad que no declaró.
class PluginCapabilityDenied implements Exception {
  const PluginCapabilityDenied(this.pluginId, this.capability);

  final String pluginId;
  final PluginCapability capability;

  @override
  String toString() =>
      'El plugin "$pluginId" intentó usar "${capability.name}" sin declararla '
      'en su manifest.';
}

/// Declaración de un plugin.
///
/// Se serializa a `manifest.json` y es lo único que el host necesita para
/// mostrar el plugin en Ajustes sin cargar su código.
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.kind,
    required this.description,
    this.author = 'Chronox AI',
    this.capabilities = const <PluginCapability>[],
    this.icon,
    this.surfaceLabel,
    this.surfaceOrder = 100,
    this.enabledByDefault = true,
    this.requires = const <String>[],
  });

  /// Identificador único, en `kebab-case` (p. ej. `git-helper`).
  final String id;
  final String name;
  final String version;
  final PluginKind kind;
  final String description;
  final String author;

  /// Capacidades que el plugin necesita. Se conceden explícitamente.
  final List<PluginCapability> capabilities;

  /// Nombre del icono (resuelto por el host a un `IconData`).
  final String? icon;

  /// Solo para [PluginKind.surface]: etiqueta de la entrada en la navegación.
  final String? surfaceLabel;

  /// Solo para [PluginKind.surface]: orden en la navegación (menor primero).
  final int surfaceOrder;

  final bool enabledByDefault;

  /// IDs de otros plugins que deben estar montados antes que este.
  final List<String> requires;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'version': version,
    'kind': kind.name,
    'description': description,
    'author': author,
    'capabilities': capabilities.map((final c) => c.name).toList(),
    'icon': icon,
    'surfaceLabel': surfaceLabel,
    'surfaceOrder': surfaceOrder,
    'enabledByDefault': enabledByDefault,
    'requires': requires,
  };

  static PluginManifest fromJson(final Map<String, Object?> json) {
    return PluginManifest(
      id: json['id']! as String,
      name: json['name']! as String,
      version: (json['version'] as String?) ?? '0.0.1',
      kind: PluginKind.values.firstWhere(
        (final k) => k.name == json['kind'],
        orElse: () => PluginKind.tool,
      ),
      description: (json['description'] as String?) ?? '',
      author: (json['author'] as String?) ?? 'desconocido',
      capabilities: ((json['capabilities'] as List<Object?>?) ?? <Object?>[])
          .map(
            (final c) => PluginCapability.values.firstWhere(
              (final k) => k.name == c,
              orElse: () => PluginCapability.fileSystem,
            ),
          )
          .toList(),
      icon: json['icon'] as String?,
      surfaceLabel: json['surfaceLabel'] as String?,
      surfaceOrder: (json['surfaceOrder'] as num?)?.toInt() ?? 100,
      enabledByDefault: (json['enabledByDefault'] as bool?) ?? true,
      requires: ((json['requires'] as List<Object?>?) ?? <Object?>[])
          .cast<String>(),
    );
  }
}

/// Acción que devuelve un [Disposable]: deshace un registro.
typedef Disposable = void Function();

/// Contexto que recibe un plugin al montarse.
///
/// Es el equivalente al `ctx` de Cordis: un registro de servicios al que el
/// plugin se engancha. Cada método `provide*` devuelve un [Disposable] que
/// **revierte exactamente ese registro**, que es la propiedad de
/// *composabilidad temporal*: desmontar un plugin no deja restos.
class PluginContext {
  PluginContext({
    required this.manifest,
    required final PluginServices services,
  }) : _services = services;

  final PluginManifest manifest;
  final PluginServices _services;

  /// Acceso a los servicios del host, filtrado por lo declarado en el manifest.
  PluginServices get services => _services.forPlugin(manifest);

  /// Define una herramienta invocable por el modelo.
  Disposable provideTool(final PluginTool tool) {
    _services.registry.add(tool);
    return () => _services.registry.remove(tool.name);
  }

  /// Define un pack de instrucciones.
  Disposable provideSkill(final PluginSkill skill) {
    _services.skills[skill.id] = skill;
    return () => _services.skills.remove(skill.id);
  }

  /// Define un modo de trabajo (composición de plugins).
  Disposable provideMode(final PluginMode mode) {
    _services.modes[mode.id] = mode;
    return () => _services.modes.remove(mode.id);
  }

  /// Define la pantalla propia del plugin.
  Disposable provideSurface(final PluginSurface surface) {
    _services.surfaces[manifest.id] = surface;
    return () => _services.surfaces.remove(manifest.id);
  }

  /// Registra un listener sobre un evento del agente.
  Disposable listen<T extends AgentEvent>(
    final void Function(T event) handler,
  ) {
    final sub = _services.events.of<T>().listen(handler);
    return sub.cancel;
  }
}

/// Ciclo de vida que implementa un plugin.
abstract class ChronoxPlugin {
  /// Se llama una vez, y solo si el plugin está habilitado.
  Future<void> mount(PluginContext context);

  /// Se llama al deshabilitar. Debe liberar lo que no sea un registro
  /// (procesos, timers, streams propios).
  Future<void> unmount() async {}
}

/// Herramienta definida por un plugin.
class PluginTool {
  const PluginTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.execute,
    this.requiresApproval = true,
  });

  final String name;
  final String description;

  /// JSON Schema de los parámetros.
  final Map<String, Object?> inputSchema;

  /// `true` si la ejecución debe pedir confirmación al usuario.
  final bool requiresApproval;

  final Future<ToolOutcome> Function(Map<String, Object?> args) execute;
}

/// Resultado de ejecutar una herramienta.
class ToolOutcome {
  const ToolOutcome({
    required this.content,
    this.isError = false,
    this.metadata = const <String, Object?>{},
  });

  const ToolOutcome.error(final String message)
    : content = message,
      isError = true,
      metadata = const <String, Object?>{};

  final String content;
  final bool isError;
  final Map<String, Object?> metadata;
}

/// Pack de instrucciones reutilizable.
class PluginSkill {
  const PluginSkill({
    required this.id,
    required this.name,
    required this.instructions,
    this.examples = const <String>[],
  });

  final String id;
  final String name;

  /// Texto que se inyecta en el system prompt cuando la skill está activa.
  final String instructions;
  final List<String> examples;
}

/// Modo de trabajo: una composición con nombre.
///
/// No contiene lógica: solo dice qué plugins se montan y con qué prompt base.
/// Así, un modo nuevo es configuración, nunca una rama en el motor.
class PluginMode {
  const PluginMode({
    required this.id,
    required this.name,
    required this.description,
    required this.pluginIds,
    this.systemPromptPrefix,
    this.icon,
  });

  final String id;
  final String name;
  final String description;

  /// Plugins que se montan al activar el modo.
  final List<String> pluginIds;

  /// Texto que se antepone al system prompt.
  final String? systemPromptPrefix;

  final String? icon;
}

/// Pantalla completa aportada por un plugin.
///
/// El host la monta en un `PluginSurfaceHost`, que aporta el andamiaje
/// (barra superior, tema, ciclo de vida) y un ámbito de estado propio.
class PluginSurface {
  const PluginSurface({
    required this.label,
    required this.icon,
    required this.builder,
    this.order = 100,
  });

  final String label;
  final IconData icon;

  /// Construye el contenido. El host ya aporta `Scaffold` y `SafeArea`.
  final Widget Function(BuildContext context, PluginSurfaceScope scope) builder;

  final int order;
}
