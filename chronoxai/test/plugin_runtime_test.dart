import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/tool_registry.dart';
import 'package:chronoxai/domain/plugins/plugin_api.dart';
import 'package:chronoxai/domain/plugins/plugin_runtime.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:flutter_test/flutter_test.dart';

/// Servicios mínimos para montar plugins en un test, sin tocar disco ni red.
PluginServices makeServices() {
  return PluginServices(
    registry: ToolRegistry(),
    skills: <String, PluginSkill>{},
    modes: <String, PluginMode>{},
    surfaces: <String, PluginSurface>{},
    events: AgentEventBus(),
  );
}

PluginManifest manifest({
  required String id,
  List<PluginCapability> capabilities = const <PluginCapability>[],
  List<String> requires = const <String>[],
  PluginKind kind = PluginKind.tool,
}) =>
    PluginManifest(
      id: id,
      name: id,
      version: '1.0.0',
      kind: kind,
      description: 'plugin de prueba',
      capabilities: capabilities,
      requires: requires,
    );

PluginTool dummyTool(String name) => PluginTool(
      name: name,
      description: 'herramienta $name',
      inputSchema: const <String, Object?>{'type': 'object'},
      execute: (final _) async => const ToolOutcome(content: 'ok'),
    );

/// Plugin que registra una herramienta con un nombre dado.
class ToolRegisteringPlugin extends ChronoxPlugin {
  ToolRegisteringPlugin(this.toolName);
  final String toolName;

  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(dummyTool(toolName));
  }
}

/// Plugin que falla a mitad del montaje.
class FailingPlugin extends ChronoxPlugin {
  @override
  Future<void> mount(final PluginContext context) async {
    context.provideTool(dummyTool('registrada-antes-de-fallar'));
    throw StateError('fallo deliberado');
  }
}

void main() {
  group('ToolRegistry', () {
    test('rechaza nombres duplicados', () {
      final registry = ToolRegistry()..add(dummyTool('foo'));

      expect(() => registry.add(dummyTool('foo')), throwsA(isA<StateError>()));
    });

    test('eliminar una herramienta la saca del registro', () {
      final registry = ToolRegistry()..add(dummyTool('foo'));
      registry.remove('foo');

      expect(registry.contains('foo'), isFalse);
      expect(registry.length, 0);
    });

    test('normaliza propiedades abreviadas de plugins a objetos JSON Schema', () {
      final registry = ToolRegistry()
        ..add(
          PluginTool(
            name: 'remote_tool',
            description: 'herramienta remota',
            inputSchema: const <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'query': 'string',
                'count': <String, Object?>{'type': 'integer'},
              },
            },
            execute: (final _) async => const ToolOutcome(content: ''),
          ),
        );

      final function = registry.toOpenAiSchemas().single['function']!
          as Map<String, Object?>;
      final parameters = function['parameters']! as Map<String, Object?>;
      final properties = parameters['properties']! as Map<String, Object?>;
      expect(properties['query'], <String, Object?>{'type': 'string'});
      expect(properties['count'], <String, Object?>{'type': 'integer'});
    });

    test('genera esquemas en formato OpenAI', () {
      final registry = ToolRegistry()
        ..add(
          PluginTool(
            name: 'read_file',
            description: 'lee',
            inputSchema: const <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'path': <String, Object?>{'type': 'string'}
              },
            },
            execute: (final _) async => const ToolOutcome(content: ''),
          ),
        );

      final schemas = registry.toOpenAiSchemas();
      expect(schemas, hasLength(1));
      expect(schemas.first['type'], 'function');
      final fn = schemas.first['function']! as Map<String, Object?>;
      expect(fn['name'], 'read_file');
      expect(fn['parameters'], isA<Map<String, Object?>>());
    });

    group('validación de argumentos', () {
      const schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string'},
          'count': <String, Object?>{'type': 'integer'},
          'mode': <String, Object?>{
            'type': 'string',
            'enum': <String>['fast', 'safe'],
          },
        },
        'required': <String>['path'],
      };

      test('acepta argumentos válidos', () {
        expect(
          ToolRegistry.validateArguments(schema, <String, Object?>{
            'path': '/a',
            'count': 3,
            'mode': 'fast',
          }),
          isEmpty,
        );
      });

      test('detecta campo requerido ausente', () {
        final problems = ToolRegistry.validateArguments(
          schema,
          <String, Object?>{},
        );
        expect(problems.single, contains('path'));
      });

      test('detecta tipo incorrecto', () {
        final problems = ToolRegistry.validateArguments(
          schema,
          <String, Object?>{'path': 42},
        );
        expect(problems.single, contains('string'));
      });

      test('detecta valor fuera del enum', () {
        final problems = ToolRegistry.validateArguments(
          schema,
          <String, Object?>{'path': '/a', 'mode': 'turbo'},
        );
        expect(problems.single, contains('fast'));
      });

      test('ignora campos no declarados en lugar de fallar', () {
        // Los modelos a veces añaden metadatos inofensivos; rechazarlos
        // provocaría bucles de reintento innecesarios.
        final problems = ToolRegistry.validateArguments(
          schema,
          <String, Object?>{'path': '/a', 'comentario_extra': 'x'},
        );
        expect(problems, isEmpty);
      });

      test('una herramienta inexistente devuelve error legible', () async {
        final outcome = await ToolRegistry().execute('no_existe', {});
        expect(outcome.isError, isTrue);
        expect(outcome.content, contains('no existe'));
      });

      test('un error dentro de la tool no propaga excepción', () async {
        final registry = ToolRegistry()
          ..add(
            PluginTool(
              name: 'boom',
              description: 'explota',
              inputSchema: const <String, Object?>{'type': 'object'},
              execute: (final _) async => throw StateError('boom'),
            ),
          );

        final outcome = await registry.execute('boom', {});
        expect(outcome.isError, isTrue);
        expect(outcome.content, contains('boom'));
      });
    });
  });

  group('PluginHost', () {
    test('montar registra las herramientas y desmontar las retira', () async {
      final services = makeServices();
      final events = AgentEventBus();
      final host = PluginHost(services: services, events: events);
      host.register(manifest(id: 'p1'), ToolRegisteringPlugin('tool_p1'));

      expect(services.registry.contains('tool_p1'), isFalse);

      expect(await host.mount('p1'), isTrue);
      expect(services.registry.contains('tool_p1'), isTrue);

      // Composición temporal: desmontar revierte exactamente lo registrado.
      await host.unmount('p1');
      expect(services.registry.contains('tool_p1'), isFalse);
    });

    test('montar dos veces no duplica registros', () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(manifest(id: 'p1'), ToolRegisteringPlugin('tool_p1'));

      await host.mount('p1');
      await host.mount('p1');

      expect(services.registry.length, 1);
    });

    test('monta las dependencias antes que el plugin que las pide', () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(manifest(id: 'base'), ToolRegisteringPlugin('tool_base'));
      host.register(
        manifest(id: 'derivado', requires: <String>['base']),
        ToolRegisteringPlugin('tool_derivado'),
      );

      expect(await host.mount('derivado'), isTrue);
      expect(services.registry.contains('tool_base'), isTrue);
      expect(services.registry.contains('tool_derivado'), isTrue);
    });

    test('falla si falta una dependencia', () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(
        manifest(id: 'huerfano', requires: <String>['no-existe']),
        ToolRegisteringPlugin('x'),
      );

      expect(await host.mount('huerfano'), isFalse);
      final plugin = host.plugins.first;
      expect(plugin.state, PluginState.failed);
      expect(plugin.error, contains('no-existe'));
    });

    test('un plugin que falla al montar queda marcado, no rompe el host',
        () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(manifest(id: 'malo'), FailingPlugin());

      expect(await host.mount('malo'), isFalse);
      expect(host.plugins.first.state, PluginState.failed);
      expect(host.mounted, isEmpty);
    });

    test('mountFlavor informa de los que fallaron', () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(manifest(id: 'bueno'), ToolRegisteringPlugin('t1'));

      final failed = await host.mountFlavor(<String>['bueno', 'fantasma']);

      expect(failed, <String>['fantasma']);
      expect(services.registry.contains('t1'), isTrue);
    });

    test('unmountAll desmonta en orden inverso y deja el registro vacío',
        () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(manifest(id: 'a'), ToolRegisteringPlugin('ta'));
      host.register(manifest(id: 'b'), ToolRegisteringPlugin('tb'));

      await host.mountFlavor(<String>['a', 'b']);
      expect(services.registry.length, 2);

      await host.unmountAll();
      expect(services.registry.length, 0);
      expect(host.mounted, isEmpty);
    });

    test('inspect devuelve el estado del runtime', () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      host.register(manifest(id: 'p1'), ToolRegisteringPlugin('tool_p1'));
      await host.mount('p1');

      final snapshot = host.inspect();
      final plugins = snapshot['plugins']! as List<Object?>;
      final tools = snapshot['tools']! as List<Object?>;

      expect(plugins, hasLength(1));
      expect(tools, contains('tool_p1'));
    });

    test('unmount llama a la limpieza propia del plugin', () async {
      final services = makeServices();
      final host = PluginHost(services: services, events: AgentEventBus());
      final plugin = _LifecicledPlugin();
      host.register(manifest(id: 'ciclo'), plugin);

      await host.mount('ciclo');
      expect(plugin.mounted, isTrue);

      await host.unmount('ciclo');
      expect(plugin.unmounted, isTrue);
    });
  });

  group('Mínimo privilegio', () {
    test('usar una capacidad no declarada lanza PluginCapabilityDenied', () {
      final services = makeServices();
      final scoped = services.forPlugin(manifest(id: 'tramposo'));

      expect(
        () => scoped.fileSystem,
        throwsA(
          isA<PluginCapabilityDenied>()
              .having((final e) => e.pluginId, 'pluginId', 'tramposo')
              .having(
                (final e) => e.capability,
                'capability',
                PluginCapability.fileSystem,
              ),
        ),
      );
    });

    test('una capacidad declarada pero sin servicio da un error explicativo',
        () {
      final services = makeServices();
      final scoped = services.forPlugin(
        manifest(
          id: 'necesita-shell',
          capabilities: <PluginCapability>[PluginCapability.shell],
        ),
      );

      expect(() => scoped.shell, throwsA(isA<StateError>()));
    });

    test('una capacidad declarada y disponible se entrega', () {
      final services = PluginServices(
        registry: ToolRegistry(),
        skills: <String, PluginSkill>{},
        modes: <String, PluginMode>{},
        surfaces: <String, PluginSurface>{},
        events: AgentEventBus(),
        shell: _FakeShell(),
      );
      final scoped = services.forPlugin(
        manifest(
          id: 'ok',
          capabilities: <PluginCapability>[PluginCapability.shell],
        ),
      );

      expect(scoped.shell, isA<ShellSeam>());
    });
  });

  group('AgentEventBus', () {
    test('filtra por tipo de evento', () async {
      final bus = AgentEventBus();
      final received = <UserMessageEvent>[];

      final sub = bus.of<UserMessageEvent>().listen(received.add);
      bus.emit(const UserMessageEvent(text: 'hola'));
      bus.emit(const AssistantDeltaEvent('ignorado'));
      bus.emit(const UserMessageEvent(text: 'otra'));
      await Future<void>.delayed(Duration.zero);

      expect(received.map((final e) => e.text), <String>['hola', 'otra']);
      await sub.cancel();
      await bus.dispose();
    });
  });
}

class _LifecicledPlugin extends ChronoxPlugin {
  bool mounted = false;
  bool unmounted = false;

  @override
  Future<void> mount(final PluginContext context) async => mounted = true;

  @override
  Future<void> unmount() async => unmounted = true;
}

class _FakeShell implements ShellSeam {
  @override
  Future<ShellResult> run(
    final String command, {
    final String? workingDirectory,
    final Duration? timeout,
  }) async =>
      const ShellResult(exitCode: 0, stdout: '', stderr: '');
}
