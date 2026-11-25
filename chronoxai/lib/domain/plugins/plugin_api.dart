import 'dart:async';

import 'package:flutter/widgets.dart';

import '../agent/agent_events.dart';
import '../agent/tool_registry.dart';
import 'seams.dart';

/// Bus de eventos tipado.
///
/// Equivalente a los eventos tipados de Cordis: quien publica no conoce a quien
/// escucha, y cancelar la suscripción no deja restos.
class AgentEventBus {
  final StreamController<AgentEvent> _controller =
      StreamController<AgentEvent>.broadcast();

  /// Emite un evento. Si nadie escucha, no pasa nada.
  void emit(final AgentEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  /// Stream filtrado por tipo.
  Stream<T> of<T extends AgentEvent>() =>
      _controller.stream.where((final e) => e is T).cast<T>();

  /// Todos los eventos.
  Stream<AgentEvent> get all => _controller.stream;

  Future<void> dispose() => _controller.close();
}

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
      requires:
          ((json['requires'] as List<Object?>?) ?? <Object?>[]).cast<String>(),
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

  /// Registros hechos por este plugin, en orden. El host los revierte al
  /// desmontar: es lo que hace que la composabilidad temporal sea real y no una
  /// promesa en la documentación.
  final List<Disposable> _registered = <Disposable>[];

  List<Disposable> get registered => List<Disposable>.unmodifiable(_registered);

  /// Acceso a los servicios del host, filtrado por lo declarado en el manifest.
  ///
  /// El getter está tipado como no-nulo a propósito: el filtrado ya garantiza
  /// que lanzar `PluginCapabilityDenied` o `StateError` si la capacidad no está
  /// concedida o el servicio no existe. Así las herramientas no tienen que
  /// comprobar nulabilidad en cada llamada (era el origen de 10 errores de
  /// `unchecked_use_of_nullable_value`).
  ScopedPluginServices get services => _services.forPlugin(manifest);

  /// Define una herramienta invocable por el modelo.
  Disposable provideTool(final PluginTool tool) {
    _services.registry.add(tool);
    return _track(() => _services.registry.remove(tool.name));
  }

  /// Define un pack de instrucciones.
  Disposable provideSkill(final PluginSkill skill) {
    _services.skills[skill.id] = skill;
    return _track(() => _services.skills.remove(skill.id));
  }

  /// Define un modo de trabajo (composición de plugins).
  Disposable provideMode(final PluginMode mode) {
    _services.modes[mode.id] = mode;
    return _track(() => _services.modes.remove(mode.id));
  }

  /// Define la pantalla propia del plugin.
  Disposable provideSurface(final PluginSurface surface) {
    _services.surfaces[manifest.id] = surface;
    return _track(() => _services.surfaces.remove(manifest.id));
  }

  /// Registra el `Disposable` para que el host pueda revertirlo.
  Disposable _track(final Disposable disposable) {
    _registered.add(disposable);
    return disposable;
  }

  /// Registra un listener sobre un evento del agente.
  Disposable listen<T extends AgentEvent>(
    final void Function(T event) handler,
  ) {
    final sub = _services.events.of<T>().listen(handler);
    return _track(sub.cancel);
  }
}

/// Servicios del host que un plugin puede consumir.
///
/// Vive en el dominio junto al contrato; las implementaciones concretas de los
/// seams (`ProotShellSeam`, etc.) van en la capa de datos.
class PluginServices {
  PluginServices({
    required this.registry,
    required this.skills,
    required this.modes,
    required this.surfaces,
    required this.events,
    this.fileSystem,
    this.shell,
    this.terminals,
    this.llm,
    this.session,
    this.network,
  });

  final ToolRegistry registry;
  final Map<String, PluginSkill> skills;
  final Map<String, PluginMode> modes;
  final Map<String, PluginSurface> surfaces;
  final AgentEventBus events;

  final FileSystemSeam? fileSystem;
  final ShellSeam? shell;
  final TerminalsSeam? terminals;
  final LlmSeam? llm;
  final SessionSeam? session;
  final NetworkSeam? network;

  /// Devuelve una vista filtrada para un plugin concreto (mínimo privilegio).
  ///
  /// El tipo de retorno es la interfaz **no nula**: el filtrado lanza si la
  /// capacidad no está concedida, así que devolver `T?` solo obligaría a cada
  /// herramienta a comprobar nulabilidad que nunca se cumple.
  ScopedPluginServices forPlugin(final PluginManifest manifest) =>
      _ScopedServices(parent: this, manifest: manifest);
}

/// Vista de servicios con garantía de no-nulidad.
///
/// `PluginServices` declara los seams como opcionales porque el host puede no
/// tenerlos (por ejemplo, sin red). Un plugin, en cambio, solo debe ver los que
/// declaró como capacidad, y si no están, recibir una excepción explicativa.
abstract class ScopedPluginServices implements PluginServices {
  @override
  FileSystemSeam get fileSystem;

  @override
  ShellSeam get shell;

  @override
  TerminalsSeam get terminals;

  @override
  LlmSeam get llm;

  @override
  SessionSeam get session;

  @override
  NetworkSeam get network;
}

class _ScopedServices extends PluginServices implements ScopedPluginServices {
  _ScopedServices({required this.parent, required this.manifest})
      : super(
          registry: parent.registry,
          skills: parent.skills,
          modes: parent.modes,
          surfaces: parent.surfaces,
          events: parent.events,
        );

  final PluginServices parent;
  final PluginManifest manifest;

  /// Devuelve el servicio o lanza. El tipo de retorno es `T` (no `T?`), de modo
  /// que quien llama no arrastra nulabilidad.
  T _require<T extends Object>(
    final PluginCapability capability,
    final T? service,
  ) {
    if (!manifest.capabilities.contains(capability)) {
      throw PluginCapabilityDenied(manifest.id, capability);
    }
    if (service == null) {
      throw StateError(
        'El servicio "${capability.name}" no está disponible en este modo. '
        'El plugin "${manifest.id}" lo necesita.',
      );
    }
    return service;
  }

  // Los `!` son seguros: `_require` ya lanza si el servicio es nulo, así que
  // aquí nunca llega null. Se declaran sin `?` para que las herramientas no
  // repitan comprobaciones en cada uso.
  @override
  FileSystemSeam get fileSystem =>
      _require(PluginCapability.fileSystem, parent.fileSystem);

  @override
  ShellSeam get shell => _require(PluginCapability.shell, parent.shell);

  @override
  TerminalsSeam get terminals =>
      _require(PluginCapability.terminals, parent.terminals);

  @override
  LlmSeam get llm => _require(PluginCapability.llm, parent.llm);

  @override
  SessionSeam get session => _require(PluginCapability.session, parent.session);

  @override
  NetworkSeam get network => _require(PluginCapability.network, parent.network);
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
    this.errorCategory,
    this.recoveryHint,
  });

  /// Constructor de error. Es `const` a propósito para que los sitios que
  /// devuelven un error fijo no generen objetos en cada invocación.
  const ToolOutcome.error(
    this.content, {
    this.errorCategory,
    this.recoveryHint,
  })  : isError = true,
        metadata = const <String, Object?>{};

  final String content;
  final bool isError;
  final Map<String, Object?> metadata;
  final String? errorCategory;
  final String? recoveryHint;
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

/// Ámbito que recibe la pantalla de un plugin.
///
/// Se declara en el dominio (y no en la capa UI) porque es parte del contrato
/// entre el host y el plugin: la UI solo lo implementa. Tenerlo aquí evita un
/// ciclo de imports entre dominio y presentación.
class PluginSurfaceScope {
  const PluginSurfaceScope({
    required this.pluginId,
    required this.setState,
    required this.showSnackBar,
    required this.openTerminal,
  });

  /// Id del plugin dueño, para mensajes de error y telemetría.
  final String pluginId;

  /// Reconstruye la pantalla del plugin.
  final void Function() setState;

  /// Muestra un mensaje efímero con el estilo de la app.
  final void Function(String message) showSnackBar;

  /// Abre la terminal del sistema.
  final Future<void> Function() openTerminal;
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
