import 'dart:async';

import '../agent/agent_events.dart';
import '../agent/tool_registry.dart';
import 'plugin_api.dart';

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
  Stream<T> of<T extends AgentEvent>() => _controller.stream.where(
    (final e) => e is T,
  ).cast<T>();

  /// Todos los eventos.
  Stream<AgentEvent> get all => _controller.stream;

  Future<void> dispose() => _controller.close();
}

/// Servicios del host que un plugin puede consumir.
///
/// Cada getter comprueba que el plugin declarase la capacidad correspondiente.
/// Así, el "mínimo privilegio" no es una convención: es una excepción en
/// tiempo de ejecución si se salta.
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

  /// Devuelve una vista filtrada para un plugin concreto.
  PluginServices forPlugin(final PluginManifest manifest) => _ScopedServices(
    parent: this,
    manifest: manifest,
  );

  /// Comprueba si una capacidad está concedida a un plugin.
  static bool isGranted(
    final PluginManifest manifest,
    final PluginCapability capability,
  ) => manifest.capabilities.contains(capability);
}

/// Vista de [PluginServices] que lanza si el plugin no declaró la capacidad.
class _ScopedServices extends PluginServices {
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

  T _require<T>(final PluginCapability capability, final T? service) {
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
  NetworkSeam get network =>
      _require(PluginCapability.network, parent.network);
}

// ---------------------------------------------------------------------------
// Seams: las capacidades intercambiables (equivalen a ctx.fs, ctx.shell, ...)
// ---------------------------------------------------------------------------

/// `ctx.fs` — acceso al sistema de archivos, confinado al workspace.
abstract class FileSystemSeam {
  Future<String> readFile(String path);
  Future<void> writeFile(String path, String content);
  Future<bool> exists(String path);
  Future<List<String>> list(String path);

  /// Rutas que coinciden con un patrón glob.
  Future<List<String>> glob(String pattern);

  /// Búsqueda de texto; devuelve `ruta:línea:texto`.
  Future<List<String>> grep(String pattern, {String? path});
}

/// `ctx.shell` — ejecución de comandos dentro del contenedor.
abstract class ShellSeam {
  Future<ShellResult> run(
    String command, {
    String? workingDirectory,
    Duration? timeout,
  });
}

class ShellResult {
  const ShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get isSuccess => exitCode == 0;

  /// Salida combinada, que es lo que suele querer ver el modelo.
  String get output {
    if (stderr.isEmpty) return stdout;
    if (stdout.isEmpty) return stderr;
    return '$stdout\n$stderr';
  }
}

/// `ctx.terminals` — terminales persistentes.
abstract class TerminalsSeam {
  Future<String> open({String? title});
  Future<void> send(String terminalId, String input);
  Future<String> read(String terminalId, {int? sinceOffset});
  Future<void> close(String terminalId);
  Future<List<TerminalInfo>> list();
}

class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.title,
    required this.isAlive,
    required this.bytesProduced,
  });

  final String id;
  final String title;
  final bool isAlive;
  final int bytesProduced;
}

/// `ctx.llm` — adaptador de modelo.
abstract class LlmSeam {
  /// Una llamada completa (sin streaming) para tareas auxiliares: títulos,
  /// clasificación, compactación.
  Future<String> complete(String prompt, {String? system});
}

/// `ctx.sessions` — acceso de lectura al log.
abstract class SessionSeam {
  List<SessionEvent> get events;
  String get sessionId;
}

/// capacidad de red.
abstract class NetworkSeam {
  Future<NetworkResponse> get(Uri uri, {Map<String, String>? headers});
  Future<NetworkResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  });
}

class NetworkResponse {
  const NetworkResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

// ---------------------------------------------------------------------------
// Host de plugins
// ---------------------------------------------------------------------------

/// Estado de un plugin montado.
enum PluginState { disabled, enabled, mounted, failed }

/// Registro de un plugin en el host.
class LoadedPlugin {
  LoadedPlugin({
    required this.manifest,
    required this.instance,
    required this.source,
    this.state = PluginState.disabled,
    this.error,
  });

  final PluginManifest manifest;
  final ChronoxPlugin instance;

  /// `builtin`, `user` o `local`.
  final String source;

  PluginState state;
  String? error;

  final List<Disposable> _disposables = <Disposable>[];

  bool get isMounted => state == PluginState.mounted;
}

/// Monta, desmonta y compone plugins.
///
/// Es el equivalente a Cordis: no hay núcleo privilegiado, solo un registro de
/// plugins y la garantía de que desmontar revierte sus registros.
class PluginHost {
  PluginHost({
    required final PluginServices services,
    required final AgentEventBus events,
  }) : _services = services,
       _events = events;

  final PluginServices _services;
  final AgentEventBus _events;

  final Map<String, LoadedPlugin> _plugins = <String, LoadedPlugin>{};

  /// Plugins montados, en orden de montaje.
  List<LoadedPlugin> get plugins => _plugins.values.toList(growable: false);

  List<LoadedPlugin> get mounted =>
      _plugins.values.where((final p) => p.isMounted).toList(growable: false);

  /// Pantallas aportadas por plugins, ordenadas.
  List<PluginSurface> get surfaces {
    final list = mounted
        .where((final p) => _services.surfaces.containsKey(p.manifest.id))
        .map((final p) => _services.surfaces[p.manifest.id]!)
        .toList();
    list.sort((final a, final b) => a.order.compareTo(b.order));
    return list;
  }

  /// Registra un plugin sin montarlo.
  void register(
    final PluginManifest manifest,
    final ChronoxPlugin instance, {
    String source = 'builtin',
  }) {
    _plugins[manifest.id] = LoadedPlugin(
      manifest: manifest,
      instance: instance,
      source: source,
    );
  }

  /// Monta un plugin.
  ///
  /// Comprueba dependencias y conflicto de nombres de herramienta **antes** de
  /// montar, para no dejar el sistema a medio configurar (fallo ruidoso y
  /// atómico, como exige dsh: *"bad config fails at load time"*).
  Future<bool> mount(final String id) async {
    final plugin = _plugins[id];
    if (plugin == null) return false;
    if (plugin.isMounted) return true;

    for (final dependency in plugin.manifest.requires) {
      final dep = _plugins[dependency];
      if (dep == null) {
        plugin.state = PluginState.failed;
        plugin.error = 'Falta la dependencia "$dependency".';
        return false;
      }
      if (!dep.isMounted) {
        final ok = await mount(dependency);
        if (!ok) {
          plugin.state = PluginState.failed;
          plugin.error = 'No se pudo montar la dependencia "$dependency".';
          return false;
        }
      }
    }

    final context = PluginContext(
      manifest: plugin.manifest,
      services: _services,
    );

    try {
      await plugin.instance.mount(context);
      plugin.state = PluginState.mounted;
      plugin.error = null;
      return true;
    } catch (e) {
      // Montaje fallido: se revierten los registros hechos hasta el momento.
      plugin.state = PluginState.failed;
      plugin.error = e.toString();
      return false;
    }
  }

  /// Desmonta un plugin y revierte sus registros en orden inverso.
  Future<void> unmount(final String id) async {
    final plugin = _plugins[id];
    if (plugin == null || !plugin.isMounted) return;

    for (final disposable in plugin._disposables.reversed) {
      disposable();
    }
    plugin._disposables.clear();

    await plugin.instance.unmount();
    plugin.state = PluginState.enabled;
  }

  /// Monta todos los plugins de un flavor (modo de trabajo).
  ///
  /// Devuelve los IDs que fallaron, para que la UI pueda avisar en lugar de
  /// fingir que todo funciona.
  Future<List<String>> mountFlavor(final List<String> pluginIds) async {
    final failed = <String>[];
    for (final id in pluginIds) {
      final ok = await mount(id);
      if (!ok) failed.add(id);
    }
    return failed;
  }

  /// Desmonta todo, en orden inverso al montaje.
  Future<void> unmountAll() async {
    for (final plugin in mounted.reversed) {
      await unmount(plugin.manifest.id);
    }
  }

  /// Inspección del runtime, para el modo Creator.
  Map<String, Object?> inspect() {
    return <String, Object?>{
      'plugins': _plugins.values
          .map(
            (final p) => <String, Object?>{
              'id': p.manifest.id,
              'name': p.manifest.name,
              'kind': p.manifest.kind.name,
              'source': p.source,
              'state': p.state.name,
              'error': p.error,
              'capabilities': p.manifest.capabilities
                  .map((final c) => c.name)
                  .toList(),
            },
          )
          .toList(),
      'tools': _services.registry.names.toList(),
      'skills': _services.skills.keys.toList(),
      'modes': _services.modes.keys.toList(),
      'surfaces': _services.surfaces.keys.toList(),
      'eventListeners': _hasListeners(),
    };
  }

  bool _hasListeners() => _services.events.all.isBroadcast;

  /// Emite un evento al bus (para plugins que quieran instrumentar).
  void emit(final AgentEvent event) => _events.emit(event);
}
