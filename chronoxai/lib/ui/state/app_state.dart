import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/llm/openai_compatible_client.dart';
import '../../data/runtime/local_runtime.dart';
import '../../domain/agent/agent_events.dart';
import '../../domain/agent/agent_loop.dart';
import '../../domain/agent/approval_policy.dart';
import '../../domain/agent/session_log.dart';
import '../../domain/agent/tool_registry.dart';
import '../../domain/llm/llm_types.dart';
import '../../domain/modes/work_modes.dart';
import '../../domain/plugins/builtin_plugins.dart';
import '../../domain/plugins/plugin_api.dart';
import '../../domain/plugins/plugin_runtime.dart';
import '../../domain/plugins/seams.dart';
import '../../domain/terminal/linux_paths.dart';
import '../../platform/android_runtime_channel.dart';

/// Ajustes del proveedor de modelo.
///
/// Se guardan en memoria por ahora; la persistencia (y el cifrado de la clave)
/// llega con la pantalla de Ajustes. La clave **nunca** va al log ni al
/// historial de la sesión.
class ProviderSettings {
  const ProviderSettings({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.model = 'deepseek-chat',
    this.apiKey = '',
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  bool get isConfigured => apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  ProviderSettings copyWith({
    final String? baseUrl,
    final String? model,
    final String? apiKey,
  }) =>
      ProviderSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );
}

/// Todo lo que compone una sesión de trabajo ya arrancada.
///
/// Se agrupa en un solo objeto porque las piezas tienen el mismo ciclo de vida:
/// si el usuario cambia de modo o de proveedor, se cierra la sesión entera y se
/// vuelve a montar, en lugar de intentar recomponer el runtime a medias.
class SessionRuntime {
  SessionRuntime({
    required this.log,
    required this.events,
    required this.registry,
    required this.policy,
    required this.loop,
    required this.host,
    required this.mode,
    required this.llm,
    required this.workspaceDir,
  });

  final SessionLog log;
  final AgentEventBus events;
  final ToolRegistry registry;
  final ApprovalPolicy policy;
  final AgentLoop loop;
  final PluginHost host;
  final PluginMode mode;
  final LlmSeam llm;
  final Directory workspaceDir;

  Future<void> dispose() async {
    for (final plugin in host.plugins) {
      await host.unmount(plugin.manifest.id);
    }
    await log.close();
    await events.dispose();
  }
}

/// Directorio donde viven las sesiones.
final appSupportDirProvider = FutureProvider<Directory>((final ref) async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/sessions');
  if (!dir.existsSync()) await dir.create(recursive: true);
  return dir;
});

/// Runtime Linux del dispositivo.
///
/// Se construye una sola vez: abrir el runtime implica leer el canal nativo y
/// comprobar ficheros, y no debe repetirse cada vez que una pantalla se
/// reconstruye.
final localRuntimeProvider = FutureProvider<LocalRuntime>((final ref) async {
  final facts = await const AndroidRuntimeChannel().read();
  final paths = LinuxPaths(
    filesDir: facts.filesDir,
    distroId: 'debian-bookworm',
  );
  await paths.ensure();
  return LocalRuntime(paths: paths);
});

/// Estado del runtime, para poder avisar antes de intentar arrancar nada.
final localRuntimeStatusProvider =
    FutureProvider<RuntimeStatus>((final ref) async {
  final runtime = await ref.watch(localRuntimeProvider.future);
  return runtime.status();
});

/// Ajustes del proveedor, editables desde Ajustes.
final providerSettingsProvider =
    StateProvider<ProviderSettings>((final ref) => const ProviderSettings());

/// Modo de trabajo activo.
final activeModeProvider =
    StateProvider<PluginMode>((final ref) => WorkModes.all.first);

/// Nivel de aprobación activo.
final approvalLevelProvider =
    StateProvider<ApprovalLevel>((final ref) => ApprovalLevel.guarded);

/// Sesión viva. `null` hasta que la UI llama a `startSession`.
final sessionProvider = StateProvider<SessionRuntime?>((final ref) => null);

/// Lo necesario para levantar una sesión: el proveedor de modelo y el shell.
///
/// El shell se inyecta desde fuera porque depende del runtime Linux, que puede
/// no estar instalado todavía. Así la UI puede arrancar en modo "sin runtime" y
/// avisar en lugar de reventar al construir.
class SessionBootstrap {
  const SessionBootstrap({
    required this.provider,
    required this.shell,
    required this.fileSystem,
    required this.workspaceDir,
    this.terminals,
    this.network,
  });

  final LlmProvider provider;
  final ShellSeam shell;
  final FileSystemSeam fileSystem;
  final Directory workspaceDir;
  final TerminalsSeam? terminals;
  final NetworkSeam? network;
}

/// Arranca una sesión completa: log, registro de herramientas, plugins y motor.
///
/// Es deliberadamente explícita (y no un `FutureProvider` que se dispara solo):
/// montar plugins y abrir ficheros de sesión son efectos que el usuario debe
/// provocar, no que ocurran porque una pantalla se reconstruyó.
Future<SessionRuntime> startSession(
  final SessionBootstrap bootstrap, {
  required final PluginMode mode,
  required final ApprovalLevel approvalLevel,
  required final Directory sessionsDir,
  final String? sessionId,
}) async {
  final id = sessionId ?? 'session-${DateTime.now().millisecondsSinceEpoch}';
  final log = await SessionLog.open(
    sessionsDir,
    id,
    modeId: mode.id,
    model: bootstrap.provider.model,
  );
  final events = AgentEventBus();
  final registry = ToolRegistry();
  final policy = ApprovalPolicy(level: approvalLevel);

  final services = PluginServices(
    registry: registry,
    skills: <String, PluginSkill>{},
    modes: <String, PluginMode>{
      for (final m in WorkModes.all) m.id: m,
    },
    surfaces: <String, PluginSurface>{},
    events: events,
    fileSystem: bootstrap.fileSystem,
    shell: bootstrap.shell,
    terminals: bootstrap.terminals,
    llm: _ProviderAsSeam(bootstrap.provider),
    network: bootstrap.network,
  );

  final host = PluginHost(services: services, events: events);

  // El runner de subagentes se conecta al motor real una vez construido; hasta
  // entonces devuelve un aviso claro en lugar de fallar en silencio.
  late final AgentLoop loop;
  final plugins = builtinPlugins(
    subagentRunner: (final prompt, final _) => loop.runSubagent(prompt),
    inspectProvider: () => <String, Object?>{
      'modelo': bootstrap.provider.model,
      'proveedor': bootstrap.provider.name,
      'modo': mode.id,
      'herramientas': registry.names.toList(),
      'plugins': host.plugins
          .map((final p) => <String, Object?>{
                'id': p.manifest.id,
                'estado': p.state.name,
                'error': p.error,
              })
          .toList(),
    },
    host: host,
    pluginLister: () => host.plugins
        .map((final p) => <String, Object?>{
              'id': p.manifest.id,
              'nombre': p.manifest.name,
              'descripcion': p.manifest.description,
              'estado': p.state.name,
              'tipo': p.manifest.kind.name,
            })
        .toList(),
  );

  for (final plugin in plugins) {
    host.register(plugin.manifest, plugin.create());
  }

  loop = AgentLoop(
    provider: bootstrap.provider,
    registry: registry,
    log: log,
    events: events,
    policy: policy,
    config: const AgentConfig(),
    modeId: mode.id,
    llm: _ProviderAsSeam(bootstrap.provider),
  );

  for (final pluginId in mode.pluginIds) {
    await host.mount(pluginId);
  }

  return SessionRuntime(
    log: log,
    events: events,
    registry: registry,
    policy: policy,
    loop: loop,
    host: host,
    mode: mode,
    llm: _ProviderAsSeam(bootstrap.provider),
    workspaceDir: bootstrap.workspaceDir,
  );
}

/// Adapta un [LlmProvider] al seam `ctx.llm` (respuestas completas sin stream).
class _ProviderAsSeam implements LlmSeam {
  _ProviderAsSeam(this.provider);

  final LlmProvider provider;

  @override
  Future<String> complete(final String prompt, {final String? system}) async {
    final messages = <LlmMessage>[
      if (system != null) LlmMessage.system(system),
      LlmMessage.user(prompt),
    ];
    final buffer = StringBuffer();
    await for (final chunk in provider.stream(
      messages: messages,
      tools: const <Map<String, Object?>>[],
    )) {
      if (chunk is TextChunk) buffer.write(chunk.text);
    }
    return buffer.toString();
  }
}

/// Crea el cliente HTTP a partir de los ajustes actuales.
OpenAiCompatibleClient clientFromSettings(final ProviderSettings settings) =>
    OpenAiCompatibleClient(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.model,
    );

/// Transcripción que pinta la pantalla de sesión.
///
/// Se deriva del log, no de un estado paralelo en memoria: si la app se cierra y
/// vuelve a abrir, la conversación sigue ahí porque el log es la verdad.
class TranscriptEntry {
  const TranscriptEntry({
    required this.kind,
    required this.text,
    this.title,
    this.isError = false,
    this.isPending = false,
  });

  final TranscriptKind kind;
  final String text;
  final String? title;
  final bool isError;
  final bool isPending;
}

enum TranscriptKind { user, assistant, tool, notice }

/// Convierte los eventos de una sesión en la lista que pinta la UI.
List<TranscriptEntry> transcriptOf(final List<SessionEvent> events) {
  final entries = <TranscriptEntry>[];
  final resolved = <String>{};

  for (final event in events) {
    switch (event) {
      case UserMessageEvent(:final text):
        entries.add(TranscriptEntry(kind: TranscriptKind.user, text: text));
      case AssistantMessageEvent(:final text) when text.trim().isNotEmpty:
        entries.add(
          TranscriptEntry(kind: TranscriptKind.assistant, text: text.trim()),
        );
      case ToolCallEvent(:final callId, :final name, :final arguments):
        entries.add(
          TranscriptEntry(
            kind: TranscriptKind.tool,
            title: name,
            text: _summariseArguments(name, arguments),
            isPending: !resolved.contains(callId),
          ),
        );
      case ToolResultEvent(:final callId, :final content, :final isError):
        resolved.add(callId);
        final index = entries.lastIndexWhere(
          (final e) => e.kind == TranscriptKind.tool && e.isPending,
        );
        if (index != -1) {
          final previous = entries[index];
          entries[index] = TranscriptEntry(
            kind: TranscriptKind.tool,
            title: previous.title,
            text: '${previous.text}\n${content.trim()}'.trim(),
            isError: isError,
          );
        } else {
          entries.add(
            TranscriptEntry(
              kind: TranscriptKind.tool,
              text: content,
              isError: isError,
            ),
          );
        }
      case CompactionEvent(:final summary):
        entries.add(
          TranscriptEntry(
            kind: TranscriptKind.notice,
            title: 'Contexto compactado',
            text: summary,
          ),
        );
      default:
        break;
    }
  }
  return entries;
}

String _summariseArguments(
  final String tool,
  final Map<String, Object?> arguments,
) {
  final path = arguments['path'];
  if (path != null) return path.toString();
  final command = arguments['command'];
  if (command != null) return command.toString();
  final pattern = arguments['pattern'];
  if (pattern != null) return pattern.toString();
  if (arguments.isEmpty) return tool;
  return arguments.entries.map((final e) => '${e.key}: ${e.value}').join('\n');
}

/// Estado derivado del motor para la barra superior.
class AgentViewState {
  const AgentViewState({
    this.isRunning = false,
    this.activity = '',
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.toolCalls = 0,
    this.error,
  });

  final bool isRunning;
  final String activity;
  final int inputTokens;
  final int outputTokens;
  final int toolCalls;
  final String? error;
}

/// Escucha los eventos efímeros del motor y los expone como estado de Riverpod.
///
/// Se suscribe una sola vez por sesión: reconstruir la pantalla no vuelve a
/// engancharse al bus (lo que duplicaría los eventos de streaming).
final agentViewProvider =
    StateNotifierProvider<AgentViewNotifier, AgentViewState>((final ref) {
  return AgentViewNotifier(ref);
});

class AgentViewNotifier extends StateNotifier<AgentViewState> {
  AgentViewNotifier(this._ref) : super(const AgentViewState()) {
    _listen();
  }

  final Ref _ref;
  final List<StreamSubscription<AgentEvent>> _subscriptions =
      <StreamSubscription<AgentEvent>>[];
  String? _boundSessionId;

  void _listen() {
    _bindNext(_ref.read(sessionProvider), initial: true);
  }

  /// Se engancha al bus de una sesión concreta. Se llama al entrar en la
  /// pantalla y cada vez que el usuario arranca o cierra una sesión.
  void sync() => _bindNext(_ref.read(sessionProvider));

  void _bindNext(final SessionRuntime? next, {final bool initial = false}) {
    final id = next?.log.sessionId;
    if (id == _boundSessionId && !initial) return;
    _boundSessionId = id;
    _unsubscribe();
    if (next == null) {
      state = const AgentViewState();
      return;
    }
    final events = next.events;
    _subscriptions.addAll(<StreamSubscription<AgentEvent>>[
      events.of<ToolStartedEvent>().listen((final _) {
        state = AgentViewState(
          isRunning: true,
          activity: 'Ejecutando herramienta…',
          inputTokens: state.inputTokens,
          outputTokens: state.outputTokens,
          toolCalls: state.toolCalls + 1,
        );
      }),
      events.of<UsageEvent>().listen((final event) {
        state = AgentViewState(
          isRunning: state.isRunning,
          activity: state.activity,
          inputTokens: state.inputTokens + event.inputTokens,
          outputTokens: state.outputTokens + event.outputTokens,
          toolCalls: state.toolCalls,
        );
      }),
      events.of<AgentErrorEvent>().listen((final event) {
        state = AgentViewState(
          isRunning: false,
          activity: state.activity,
          inputTokens: state.inputTokens,
          outputTokens: state.outputTokens,
          toolCalls: state.toolCalls,
          error: event.message,
        );
      }),
    ]);
    state = const AgentViewState();
  }

  /// Marca el motor como ocupado. Lo llama la pantalla al enviar un mensaje.
  void markRunning(final String activity) {
    state = AgentViewState(
      isRunning: true,
      activity: activity,
      inputTokens: state.inputTokens,
      outputTokens: state.outputTokens,
      toolCalls: state.toolCalls,
    );
  }

  /// El turno terminó: se refleja el motivo si no fue un cierre normal.
  void markFinished(final String reason) {
    state = AgentViewState(
      isRunning: false,
      activity: '',
      inputTokens: state.inputTokens,
      outputTokens: state.outputTokens,
      toolCalls: state.toolCalls,
      error: switch (reason) {
        'completed' => null,
        'cancelled' => 'Turno cancelado.',
        'maxSteps' => 'Se alcanzó el límite de pasos del turno.',
        'rejected' => 'Rechazaste una acción; el turno se detuvo.',
        _ => state.error ?? 'El turno falló.',
      },
    );
  }

  void clearError() {
    state = AgentViewState(
      isRunning: state.isRunning,
      activity: state.activity,
      inputTokens: state.inputTokens,
      outputTokens: state.outputTokens,
      toolCalls: state.toolCalls,
    );
  }

  void _unsubscribe() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}
