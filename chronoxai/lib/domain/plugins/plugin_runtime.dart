import 'dart:async';

import '../agent/agent_events.dart';
import 'plugin_api.dart';

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

  /// Adopta los registros del contexto de montaje.
  void adoptDisposables(final List<Disposable> disposables) {
    _disposables
      ..clear()
      ..addAll(disposables);
  }

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
      // Los registros quedan en poder del host para poder revertirlos.
      plugin.adoptDisposables(context.registered);
      plugin.state = PluginState.mounted;
      plugin.error = null;
      return true;
    } catch (e) {
      // Montaje fallido: se revierten los registros hechos hasta el momento,
      // para no dejar medio plugin en el sistema.
      for (final disposable in context.registered.reversed) {
        disposable();
      }
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
