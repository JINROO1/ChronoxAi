import 'dart:async';
import 'dart:convert';

import '../llm/llm_types.dart';
import '../plugins/plugin_api.dart';
import '../plugins/seams.dart';
import 'agent_events.dart';
import 'approval_policy.dart';
import 'prompt_builder.dart';
import 'session_log.dart';
import 'tool_registry.dart';

/// Quién responde cuando el motor pide aprobación.
///
/// Se inyecta desde la UI. Si no se proporciona, el motor rechaza las acciones
/// que necesitan permiso: fallar hacia el lado seguro es preferible a ejecutar
/// algo destructivo sin que nadie lo haya visto.
typedef ApprovalHandler = Future<ApprovalAnswer> Function(
    ApprovalRequest request);

class ApprovalRequest {
  const ApprovalRequest({
    required this.callId,
    required this.toolName,
    required this.preview,
    this.diff,
  });

  final String callId;
  final String toolName;
  final String preview;
  final String? diff;
}

class ApprovalAnswer {
  const ApprovalAnswer({
    required this.approved,
    this.rememberForSession = false,
  });

  const ApprovalAnswer.denied()
      : approved = false,
        rememberForSession = false;

  final bool approved;
  final bool rememberForSession;
}

/// Configuración del motor.
class AgentConfig {
  const AgentConfig({
    this.maxStepsPerTurn = 40,
    this.maxRetries = 3,
    this.retryBaseDelay = const Duration(seconds: 2),
    this.temperature,
    this.maxTokens,
    this.toolOutputBudget = 12000,
    this.contextBudget = 96000,
    this.compactThreshold = 0.8,
  });

  /// Tope de pasos por turno. Evita bucles infinitos del modelo.
  final int maxStepsPerTurn;

  /// Reintentos ante errores recuperables (429, 5xx, red).
  final int maxRetries;
  final Duration retryBaseDelay;

  final double? temperature;
  final int? maxTokens;

  /// Caracteres máximos de salida de una herramienta antes de truncar.
  final int toolOutputBudget;

  /// Tokens de contexto disponibles antes de compactar.
  final int contextBudget;

  /// Fracción del presupuesto a la que se dispara la compactación.
  final double compactThreshold;
}

/// Estado observable del motor, para la UI.
class AgentStatus {
  const AgentStatus({
    this.isRunning = false,
    this.currentStep = 0,
    this.activity = '',
  });

  final bool isRunning;
  final int currentStep;
  final String activity;

  AgentStatus copyWith({bool? isRunning, int? currentStep, String? activity}) =>
      AgentStatus(
        isRunning: isRunning ?? this.isRunning,
        currentStep: currentStep ?? this.currentStep,
        activity: activity ?? this.activity,
      );
}

/// El driver del agente: el equivalente a `ctx.agentLoop` de DeepSeek Harness.
///
/// Implementa el flujo `turn → step → tool`, con:
/// * streaming de tokens hacia la UI;
/// * cancelación **real** (aborta la petición HTTP en curso);
/// * reintentos con backoff exponencial solo en errores recuperables;
/// * aprobación por herramienta según la política;
/// * compactación de contexto cuando se acerca al límite;
/// * todo evento durable va al `SessionLog`, que es la fuente de verdad.
class AgentLoop {
  AgentLoop({
    required this.provider,
    required this.registry,
    required this.log,
    required this.events,
    required this.policy,
    required this.config,
    required this.modeId,
    ApprovalHandler? approvalHandler,
    LlmSeam? llm,
  })  : _approvalHandler = approvalHandler,
        _llm = llm;

  final LlmProvider provider;
  final ToolRegistry registry;
  final SessionLog log;
  final AgentEventBus events;
  final ApprovalPolicy policy;
  final AgentConfig config;
  final String modeId;

  ApprovalHandler? _approvalHandler;
  final LlmSeam? _llm;

  /// Permite a la UI enganchar su diálogo de aprobación después de construir.
  set approvalHandler(final ApprovalHandler? handler) =>
      _approvalHandler = handler;

  StreamSubscription<LlmChunk>? _activeStream;
  Completer<void>? _cancelSignal;
  bool _cancelled = false;

  /// Cierra la petición en curso con lo recibido hasta el momento.
  ///
  /// Sin esto, cancelar la suscripción deja el `Completer` del paso sin
  /// completar y el turno se queda colgado para siempre.
  void Function()? _abortActiveRequest;

  AgentStatus _status = const AgentStatus();
  AgentStatus get status => _status;

  /// Ejecuta un turno completo en respuesta a [userInput].
  ///
  /// Devuelve el motivo de cierre: `completed`, `cancelled`, `maxSteps`,
  /// `rejected` o `error`.
  Future<String> runTurn(final String userInput) async {
    if (_status.isRunning) {
      throw StateError(
          'Ya hay un turno en curso. Cancélalo antes de empezar otro.');
    }

    _cancelled = false;
    _cancelSignal = Completer<void>();
    _status = const AgentStatus(isRunning: true, activity: 'Pensando…');

    final turnId = 'turn-${DateTime.now().microsecondsSinceEpoch}';
    await log.append(TurnStartEvent(turnId: turnId, userInput: userInput));
    await log.append(UserMessageEvent(text: userInput));

    var reason = 'completed';
    try {
      reason = await _runSteps(turnId);
    } on LlmException catch (e) {
      if (_cancelled) {
        reason = 'cancelled';
      } else {
        events.emit(
          AgentErrorEvent(message: humanMessage(e), isRetryable: e.isRetryable),
        );
        reason = 'error';
      }
    } catch (e) {
      events.emit(AgentErrorEvent(message: 'Error inesperado: $e'));
      reason = 'error';
    } finally {
      await log.append(TurnEndEvent(turnId: turnId, reason: reason));
      _status = const AgentStatus(isRunning: false);
      _activeStream = null;
      _abortActiveRequest = null;
      _cancelSignal = null;
    }
    return reason;
  }

  Future<String> _runSteps(final String turnId) async {
    final toolSchemas = registry.toOpenAiSchemas();
    var stepIndex = 0;

    while (stepIndex < config.maxStepsPerTurn) {
      if (_cancelled) return 'cancelled';

      _status = _status.copyWith(
        currentStep: stepIndex,
        activity: stepIndex == 0 ? 'Pensando…' : 'Continuando…',
      );
      await log.append(StepStartEvent(stepIndex: stepIndex));

      final messages = await _buildMessages();
      final started = DateTime.now();
      int? firstTokenAt;

      final response = await _streamWithRetries(
        messages: messages,
        tools: toolSchemas,
        onFirstToken: () =>
            firstTokenAt ??= DateTime.now().difference(started).inMilliseconds,
      );

      if (_cancelled) return 'cancelled';

      // 1. Persistir el mensaje del asistente (texto + razonamiento).
      await log.append(
        AssistantMessageEvent(
          text: response.content,
          reasoning: response.reasoning,
          toolCallIds: response.toolCalls.map((final c) => c.id).toList(),
          stopReason: response.stopReason,
        ),
      );

      // 2. Sin herramientas: el turno terminó.
      if (!response.wantsTools) {
        await log.append(
          StepEndEvent(
            stepIndex: stepIndex,
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens,
            timeToFirstTokenMs: firstTokenAt,
            durationMs: DateTime.now().difference(started).inMilliseconds,
          ),
        );
        return 'completed';
      }

      // 3. Ejecutar herramientas.
      final toolStarted = DateTime.now();
      var rejected = false;
      for (final call in response.toolCalls) {
        if (_cancelled) return 'cancelled';
        final outcome = await _executeTool(call);
        if (outcome == _ToolExecutionOutcome.rejected) rejected = true;
      }

      await log.append(
        StepEndEvent(
          stepIndex: stepIndex,
          inputTokens: response.usage.inputTokens,
          outputTokens: response.usage.outputTokens,
          timeToFirstTokenMs: firstTokenAt,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          toolTimeMs: DateTime.now().difference(toolStarted).inMilliseconds,
        ),
      );

      events.emit(
        UsageEvent(
          inputTokens: response.usage.inputTokens,
          outputTokens: response.usage.outputTokens,
          cachedInputTokens: response.usage.cachedInputTokens,
        ),
      );

      if (rejected) return 'rejected';

      await _maybeCompact();
      stepIndex++;
    }

    return 'maxSteps';
  }

  /// Pide al modelo, reintentando solo lo que tiene sentido reintentar.
  Future<LlmResponse> _streamWithRetries({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    required final void Function() onFirstToken,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await _consumeStream(
          messages: messages,
          tools: tools,
          onFirstToken: onFirstToken,
        );
      } on LlmException catch (error) {
        if (error.kind == LlmErrorKind.contextLength) {
          // Compactar y reintentar una vez: es recuperable, pero no bucle.
          if (attempt == 0) {
            await _compact(force: true);
            attempt++;
            continue;
          }
          rethrow;
        }
        if (!error.isRetryable || attempt >= config.maxRetries) rethrow;

        attempt++;
        final delay =
            error.retryAfter ?? config.retryBaseDelay * (1 << (attempt - 1));
        _status = _status.copyWith(
          activity: 'Reintentando en ${delay.inSeconds}s '
              '(${attempt}/${config.maxRetries})…',
        );
        await Future<void>.delayed(delay);
        if (_cancelled) {
          throw const LlmException(LlmErrorKind.network, 'Cancelado');
        }
      }
    }
  }

  Future<LlmResponse> _consumeStream({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    required final void Function() onFirstToken,
  }) async {
    final contentBuffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    final toolCalls = <int, LlmToolCall>{};
    var usage = const LlmUsage();
    String? stopReason;
    var sawFirstToken = false;

    final completer = Completer<LlmResponse>();
    _abortActiveRequest = () {
      if (completer.isCompleted) return;
      completer.complete(
        LlmResponse(
          content: contentBuffer.toString(),
          reasoning:
              reasoningBuffer.isEmpty ? null : reasoningBuffer.toString(),
          usage: usage,
          stopReason: 'cancelled',
        ),
      );
    };
    _activeStream = provider
        .stream(
      messages: messages,
      tools: tools,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
    )
        .listen(
      (final chunk) {
        switch (chunk) {
          case TextChunk(:final text):
            if (!sawFirstToken) {
              sawFirstToken = true;
              onFirstToken();
            }
            contentBuffer.write(text);
            events.emit(AssistantDeltaEvent(text));
          case ReasoningChunk(:final text):
            reasoningBuffer.write(text);
            events.emit(ReasoningDeltaEvent(text));
          case ToolCallChunk(
              :final index,
              :final id,
              :final name,
              :final argumentsFragment
            ):
            // Los fragmentos ya vienen ensamblados por el cliente: aquí solo
            // se guarda la versión final de cada índice.
            if (id != null && name != null && argumentsFragment != null) {
              final decoded = _tryDecode(argumentsFragment);
              toolCalls[index] = LlmToolCall(
                id: id,
                name: name,
                arguments: decoded ?? const <String, Object?>{},
                parseError: decoded == null
                    ? 'JSON inválido en los argumentos: $argumentsFragment'
                    : null,
              );
            }
          case DoneChunk():
            usage = chunk.usage;
            stopReason = chunk.stopReason;
        }
      },
      onError: (final Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            error is LlmException
                ? error
                : LlmException(LlmErrorKind.network, 'Error de red: $error'),
          );
        }
      },
      onDone: () {
        if (completer.isCompleted) return;
        completer.complete(
          LlmResponse(
            content: contentBuffer.toString(),
            toolCalls: toolCalls.values.toList(),
            reasoning:
                reasoningBuffer.isEmpty ? null : reasoningBuffer.toString(),
            usage: usage,
            stopReason: stopReason,
          ),
        );
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  static Map<String, Object?>? _tryDecode(final String raw) {
    if (raw.trim().isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Ejecuta una herramienta pasando por la política de aprobación.
  Future<_ToolExecutionOutcome> _executeTool(final LlmToolCall call) async {
    await log.append(
      ToolCallEvent(
          callId: call.id, name: call.name, arguments: call.arguments),
    );

    final tool = registry[call.name];
    if (tool == null) {
      await _recordResult(
        call,
        'La herramienta "${call.name}" no existe.',
        isError: true,
      );
      return _ToolExecutionOutcome.failed;
    }

    // Si el modelo mandó argumentos ilegibles, se le pide corregir en lugar de
    // ejecutar con un mapa vacío (que podría borrar algo por accidente).
    if (call.parseError != null) {
      await _recordResult(call, call.parseError!, isError: true);
      return _ToolExecutionOutcome.failed;
    }

    final verdict = policy.check(tool);
    if (verdict.isDenied) {
      await _recordResult(call, verdict.reason ?? 'Rechazado.', isError: true);
      return _ToolExecutionOutcome.rejected;
    }

    if (verdict.needsUser) {
      final answer = await _askApproval(call, tool);
      await log.append(
        ApprovalDecisionEvent(
          callId: call.id,
          approved: answer.approved,
          rememberForSession: answer.rememberForSession,
        ),
      );
      if (!answer.approved) {
        await _recordResult(
          call,
          'El usuario rechazó la ejecución de "${call.name}". '
          'No lo reintentes sin cambiar de enfoque.',
          isError: true,
        );
        return _ToolExecutionOutcome.rejected;
      }
      if (answer.rememberForSession) policy.trust(call.name);
    }

    events.emit(ToolStartedEvent(callId: call.id, name: call.name));
    _status = _status.copyWith(activity: 'Ejecutando ${call.name}…');
    final started = DateTime.now();

    final outcome = await registry.execute(call.name, call.arguments);
    final duration = DateTime.now().difference(started).inMilliseconds;

    await _recordResult(
      call,
      outcome.content,
      isError: outcome.isError,
      durationMs: duration,
    );
    return outcome.isError
        ? _ToolExecutionOutcome.failed
        : _ToolExecutionOutcome.ok;
  }

  Future<ApprovalAnswer> _askApproval(
    final LlmToolCall call,
    final PluginTool tool,
  ) async {
    final handler = _approvalHandler;
    final preview = _previewFor(call);
    events.emit(
      ApprovalRequestedEvent(
        callId: call.id,
        toolName: call.name,
        preview: preview,
        diff: _diffFor(call),
      ),
    );

    if (handler == null) {
      // Sin UI que pregunte: se rechaza. Fallar hacia el lado seguro.
      return const ApprovalAnswer.denied();
    }
    return handler(
      ApprovalRequest(
        callId: call.id,
        toolName: call.name,
        preview: preview,
        diff: _diffFor(call),
      ),
    );
  }

  /// Texto corto y preciso de lo que se va a ejecutar.
  static String _previewFor(final LlmToolCall call) {
    final args = call.arguments;
    return switch (call.name) {
      'bash' ||
      'run_code' =>
        (args['command'] ?? args['code'] ?? '').toString(),
      'write' => 'Escribir ${args['path']}',
      'edit' => 'Editar ${args['path']}',
      'apply_patch' => 'Aplicar patch',
      'terminal_send' => 'Enviar a terminal: ${args['input']}',
      _ => args.isEmpty ? call.name : '$call.name(${args.keys.join(', ')})',
    };
  }

  /// Diff unificado, cuando la herramienta lo permite calcular.
  String? _diffFor(final LlmToolCall call) {
    if (call.name == 'edit') {
      final oldStr = call.arguments['old_str']?.toString() ?? '';
      final newStr = call.arguments['new_str']?.toString() ?? '';
      return '- $oldStr\n+ $newStr';
    }
    return null;
  }

  Future<void> _recordResult(
    final LlmToolCall call,
    final String content, {
    required final bool isError,
    final int durationMs = 0,
  }) async {
    final truncated = content.length > config.toolOutputBudget;
    final clipped = truncated
        ? '${content.substring(0, config.toolOutputBudget)}\n\n'
            '[salida truncada: ${content.length - config.toolOutputBudget} '
            'caracteres omitidos]'
        : content;

    await log.append(
      ToolResultEvent(
        callId: call.id,
        name: call.name,
        content: clipped,
        isError: isError,
        durationMs: durationMs,
        truncated: truncated,
      ),
    );
  }

  /// Construye la lista de mensajes que ve el modelo.
  ///
  /// Se reconstruye desde el log, no desde el estado en memoria: así el
  /// histórico sobrevive a un reinicio de la app y coincide exactamente con lo
  /// que ya se le mostró al modelo (invariante *model-visible means logged*).
  ///
  /// Dos detalles que hacen que los proveedores no rechacen la petición:
  /// * un mensaje `assistant` con `tool_calls` debe repetirlas tal cual;
  /// * un mensaje `tool` solo es válido si responde a una llamada previa, así
  ///   que se descartan los resultados huérfanos (pueden aparecer justo después
  ///   de una compactación).
  Future<List<LlmMessage>> _buildMessages() async {
    final history = log.modelVisibleHistory();

    final callsById = <String, ToolCallEvent>{};
    for (final event in history) {
      if (event is ToolCallEvent) callsById[event.callId] = event;
    }

    final messages = <LlmMessage>[
      LlmMessage.system(
        PromptBuilder.build(
          modeId: modeId,
          tools: registry.all.toList(),
          log: log,
        ),
      ),
    ];
    final pendingCallIds = <String>{};

    for (final event in history) {
      if (event is CompactionEvent) {
        messages.add(
          LlmMessage.system(
            'Resumen del trabajo anterior (el contexto se compactó):\n'
            '${event.summary}',
          ),
        );
      } else if (event is UserMessageEvent) {
        messages.add(LlmMessage.user(event.text));
      } else if (event is AssistantMessageEvent) {
        final calls = <LlmToolCall>[];
        for (final id in event.toolCallIds) {
          final recorded = callsById[id];
          if (recorded == null) continue;
          calls.add(
            LlmToolCall(
              id: recorded.callId,
              name: recorded.name,
              arguments: recorded.arguments,
            ),
          );
          pendingCallIds.add(id);
        }
        if (event.text.trim().isEmpty && calls.isEmpty) continue;
        messages.add(
          LlmMessage.assistant(
            event.text,
            toolCalls: calls,
            reasoning: event.reasoning,
          ),
        );
      } else if (event is ToolResultEvent) {
        if (!pendingCallIds.remove(event.callId)) continue;
        messages.add(
          LlmMessage.toolResult(
              toolCallId: event.callId, content: event.content),
        );
      }
    }
    return messages;
  }

  /// Compacta si el log se acerca al presupuesto de contexto.
  Future<void> _maybeCompact() async {
    final approxTokens = _estimateTokens();
    final threshold = (config.contextBudget * config.compactThreshold).round();
    if (approxTokens < threshold) return;
    await _compact();
  }

  /// Estimación de tokens sin tokenizer por modelo.
  ///
  /// ~4 caracteres por token es la aproximación estándar para texto latino; se
  /// prefiere a incluir un tokenizer de varios MB que solo acertaría con un
  /// proveedor concreto. El objetivo es disparar la compactación a tiempo, no
  /// facturar.
  int _estimateTokens() {
    var chars = 0;
    for (final event in log.events) {
      switch (event) {
        case UserMessageEvent(:final text):
          chars += text.length;
        case AssistantMessageEvent(:final text, :final reasoning):
          chars += text.length + (reasoning?.length ?? 0);
        case ToolResultEvent(:final content):
          chars += content.length;
        default:
          break;
      }
    }
    return chars ~/ 4;
  }

  /// Sustituye el contexto antiguo por un resumen.
  ///
  /// Si hay un proveedor disponible se le pide un resumen real; si no, se genera
  /// uno determinista a partir de los eventos. Nunca se borra el log: se añade un
  /// `CompactionEvent` y el historial visible se corta ahí (fork/rewind siguen
  /// funcionando).
  Future<void> _compact({final bool force = false}) async {
    final before = log.events.length;
    if (!force && before < 6) return;

    final tokensBefore = _estimateTokens();
    final keepFrom = (before - 8).clamp(1, before);
    final older = log.events.sublist(0, keepFrom);

    String summary;
    final llm = _llm;
    if (llm != null) {
      try {
        summary = await llm.complete(
          'Resume en viñetas breves lo que se ha hecho hasta ahora, '
          'centrándote en decisiones, ficheros tocados y pendientes:\n\n'
          '${PromptBuilder.transcriptForSummary(older)}',
          system:
              'Eres un asistente que resume trabajo técnico de forma concisa.',
        );
      } catch (_) {
        summary = PromptBuilder.deterministicSummary(older);
      }
    } else {
      summary = PromptBuilder.deterministicSummary(older);
    }

    await log.append(
      CompactionEvent(
        summary: summary,
        replacedEventCount: keepFrom,
        tokensBefore: tokensBefore,
        tokensAfter: summary.length ~/ 4,
      ),
    );
  }

  /// Cancela el turno en curso y **aborta la petición HTTP**.
  Future<void> cancel() async {
    _cancelled = true;
    _abortActiveRequest?.call();
    _abortActiveRequest = null;
    await _activeStream?.cancel();
    _activeStream = null;
    if (_cancelSignal != null && !_cancelSignal!.isCompleted) {
      _cancelSignal!.complete();
    }
    _status = _status.copyWith(isRunning: false, activity: 'Cancelado');
  }

  /// Traduce un error del proveedor a algo accionable para el usuario.
  ///
  /// El mensaje crudo de una API ("401 Unauthorized: invalid_api_key") no dice
  /// a nadie qué hacer; el tipo de error sí.
  static String humanMessage(final LlmException error) => switch (error.kind) {
        LlmErrorKind.auth =>
          'La clave de API no es válida o ha caducado. Revísala en Ajustes.',
        LlmErrorKind.rateLimit =>
          'El proveedor está limitando las peticiones. Espera unos segundos y '
              'vuelve a intentarlo.',
        LlmErrorKind.contextLength =>
          'La conversación no cabe en el contexto del modelo ni después de '
              'compactarla. Empieza una sesión nueva.',
        LlmErrorKind.network =>
          'No se pudo conectar con el proveedor. Comprueba tu conexión: '
              '${error.message}',
        LlmErrorKind.server =>
          'El proveedor devolvió un error (${error.statusCode ?? '?'}). '
              'Reintenta en unos segundos.',
        LlmErrorKind.unknown => error.message,
      };

  /// Ejecuta un subagente con el mismo proveedor y registro, en un turno propio.
  ///
  /// El resultado es solo el texto final: el subagente no contamina el contexto
  /// principal, que es justo para lo que existe.
  Future<String> runSubagent(final String prompt) async {
    final messages = <LlmMessage>[
      LlmMessage.system(
        'Eres un subagente. Resuelve la tarea de forma autónoma y devuelve solo '
        'el resultado, sin explicar tu proceso.',
      ),
      LlmMessage.user(prompt),
    ];

    final response = await _consumeStream(
      messages: messages,
      tools: const <Map<String, Object?>>[],
      onFirstToken: () {},
    );
    return response.content;
  }
}

enum _ToolExecutionOutcome { ok, failed, rejected }
