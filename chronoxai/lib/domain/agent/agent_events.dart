/// Eventos del motor del agente.
///
/// Modelo tomado de dsh: los eventos son **tipados** y se separan en dos clases
/// según su duración.
///
/// * **Durables** (`SessionEvent`): se escriben en el log append-only. Son la
///   única fuente de verdad; de ellos se derivan la UI, el fork, el rewind y la
///   telemetría. Regla de dsh: *"model-visible means logged"*.
/// * **Efímeros** (`AgentEvent` que no es `SessionEvent`): solo alimentan la UI
///   en vivo (tokens según llegan). Nunca se persisten.
sealed class AgentEvent {
  const AgentEvent();

  /// Marca temporal del evento.
  DateTime get timestamp => DateTime.now();
}

/// Evento que se persiste en el log de sesión.
abstract class SessionEvent extends AgentEvent {
  const SessionEvent();

  /// Nombre estable del tipo, usado en JSONL (`"type": "tool/call"`).
  String get eventType;

  Map<String, Object?> toJson();

  /// Reconstruye un evento desde el log.
  static SessionEvent? fromJson(final Map<String, Object?> json) {
    final type = json['type'] as String?;
    final data =
        (json['data'] as Map<String, Object?>?) ?? const <String, Object?>{};
    return switch (type) {
      'turn/start' => TurnStartEvent.fromJson(data),
      'turn/end' => TurnEndEvent.fromJson(data),
      'step/start' => StepStartEvent.fromJson(data),
      'step/end' => StepEndEvent.fromJson(data),
      'user/message' => UserMessageEvent.fromJson(data),
      'assistant/message' => AssistantMessageEvent.fromJson(data),
      'tool/call' => ToolCallEvent.fromJson(data),
      'tool/result' => ToolResultEvent.fromJson(data),
      'approval/decision' => ApprovalDecisionEvent.fromJson(data),
      'plan/decision' => PlanDecisionEvent.fromJson(data),
      'compaction' => CompactionEvent.fromJson(data),
      'session/created' => SessionCreatedEvent.fromJson(data),
      'session/title' => SessionTitleEvent.fromJson(data),
      _ => null,
    };
  }
}

// ---------------------------------------------------------------------------
// Ciclo de vida
// ---------------------------------------------------------------------------

/// Primer evento de una sesión.
class SessionCreatedEvent extends SessionEvent {
  const SessionCreatedEvent({
    required this.sessionId,
    required this.modeId,
    required this.model,
    required this.createdAt,
  });

  final String sessionId;
  final String modeId;
  final String model;
  final DateTime createdAt;

  @override
  String get eventType => 'session/created';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'sessionId': sessionId,
        'modeId': modeId,
        'model': model,
        'createdAt': createdAt.toIso8601String(),
      };

  static SessionCreatedEvent fromJson(final Map<String, Object?> j) =>
      SessionCreatedEvent(
        sessionId: j['sessionId']! as String,
        modeId: (j['modeId'] as String?) ?? 'standard',
        model: (j['model'] as String?) ?? '',
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// Título legible de la sesión (lo genera un proveedor de títulos).
class SessionTitleEvent extends SessionEvent {
  const SessionTitleEvent({required this.title});

  final String title;

  @override
  String get eventType => 'session/title';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'title': title};

  static SessionTitleEvent fromJson(final Map<String, Object?> j) =>
      SessionTitleEvent(title: (j['title'] as String?) ?? '');
}

/// Apertura de turno. Un turno es la respuesta completa a un input del usuario.
class TurnStartEvent extends SessionEvent {
  const TurnStartEvent({required this.turnId, this.userInput});

  final String turnId;
  final String? userInput;

  @override
  String get eventType => 'turn/start';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'turnId': turnId,
        'userInput': userInput,
      };

  static TurnStartEvent fromJson(final Map<String, Object?> j) =>
      TurnStartEvent(
        turnId: (j['turnId'] as String?) ?? '',
        userInput: j['userInput'] as String?,
      );
}

/// Cierre de turno, con el motivo.
class TurnEndEvent extends SessionEvent {
  const TurnEndEvent({required this.turnId, required this.reason});

  final String turnId;

  /// `completed`, `cancelled`, `maxSteps`, `error`, `rejected`.
  final String reason;

  @override
  String get eventType => 'turn/end';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'turnId': turnId,
        'reason': reason,
      };

  static TurnEndEvent fromJson(final Map<String, Object?> j) => TurnEndEvent(
        turnId: (j['turnId'] as String?) ?? '',
        reason: (j['reason'] as String?) ?? 'completed',
      );
}

/// Un paso = una petición al modelo + sus herramientas.
class StepStartEvent extends SessionEvent {
  const StepStartEvent({required this.stepIndex});

  final int stepIndex;

  @override
  String get eventType => 'step/start';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'stepIndex': stepIndex};

  static StepStartEvent fromJson(final Map<String, Object?> j) =>
      StepStartEvent(stepIndex: (j['stepIndex'] as num?)?.toInt() ?? 0);
}

/// Cierre de paso, con métricas de rendimiento (equivalente al *Trajectory* de dsh).
class StepEndEvent extends SessionEvent {
  const StepEndEvent({
    required this.stepIndex,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.timeToFirstTokenMs,
    this.durationMs = 0,
    this.toolTimeMs = 0,
  });

  final int stepIndex;
  final int inputTokens;
  final int outputTokens;
  final int? timeToFirstTokenMs;
  final int durationMs;
  final int toolTimeMs;

  @override
  String get eventType => 'step/end';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'stepIndex': stepIndex,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'timeToFirstTokenMs': timeToFirstTokenMs,
        'durationMs': durationMs,
        'toolTimeMs': toolTimeMs,
      };

  static StepEndEvent fromJson(final Map<String, Object?> j) => StepEndEvent(
        stepIndex: (j['stepIndex'] as num?)?.toInt() ?? 0,
        inputTokens: (j['inputTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (j['outputTokens'] as num?)?.toInt() ?? 0,
        timeToFirstTokenMs: (j['timeToFirstTokenMs'] as num?)?.toInt(),
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        toolTimeMs: (j['toolTimeMs'] as num?)?.toInt() ?? 0,
      );
}

// ---------------------------------------------------------------------------
// Mensajes
// ---------------------------------------------------------------------------

/// Mensaje del usuario.
class UserMessageEvent extends SessionEvent {
  const UserMessageEvent(
      {required this.text, this.attachments = const <String>[]});

  final String text;
  final List<String> attachments;

  @override
  String get eventType => 'user/message';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'attachments': attachments,
      };

  static UserMessageEvent fromJson(final Map<String, Object?> j) =>
      UserMessageEvent(
        text: (j['text'] as String?) ?? '',
        attachments: ((j['attachments'] as List<Object?>?) ?? const <Object?>[])
            .cast<String>(),
      );
}

/// Mensaje del asistente, ya completo (el streaming no se persiste).
class AssistantMessageEvent extends SessionEvent {
  const AssistantMessageEvent({
    required this.text,
    this.reasoning,
    this.toolCallIds = const <String>[],
    this.stopReason,
  });

  final String text;

  /// Razonamiento del modelo, si el proveedor lo expone.
  final String? reasoning;

  final List<String> toolCallIds;
  final String? stopReason;

  @override
  String get eventType => 'assistant/message';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'reasoning': reasoning,
        'toolCallIds': toolCallIds,
        'stopReason': stopReason,
      };

  static AssistantMessageEvent fromJson(final Map<String, Object?> j) =>
      AssistantMessageEvent(
        text: (j['text'] as String?) ?? '',
        reasoning: j['reasoning'] as String?,
        toolCallIds: ((j['toolCallIds'] as List<Object?>?) ?? const <Object?>[])
            .cast<String>(),
        stopReason: j['stopReason'] as String?,
      );
}

// ---------------------------------------------------------------------------
// Herramientas
// ---------------------------------------------------------------------------

/// Invocación de una herramienta por el modelo.
class ToolCallEvent extends SessionEvent {
  const ToolCallEvent({
    required this.callId,
    required this.name,
    required this.arguments,
  });

  final String callId;
  final String name;
  final Map<String, Object?> arguments;

  @override
  String get eventType => 'tool/call';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'callId': callId,
        'name': name,
        'arguments': arguments,
      };

  static ToolCallEvent fromJson(final Map<String, Object?> j) => ToolCallEvent(
        callId: (j['callId'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        arguments: (j['arguments'] as Map<String, Object?>?) ??
            const <String, Object?>{},
      );
}

/// Resultado de una herramienta.
class ToolResultEvent extends SessionEvent {
  const ToolResultEvent({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
    this.durationMs = 0,
    this.truncated = false,
    this.errorCategory,
    this.recoveryHint,
    this.exitCode,
  });

  final String callId;
  final String name;
  final String content;
  final bool isError;
  final int durationMs;

  /// `true` si la salida se recortó por presupuesto de contexto.
  final bool truncated;

  /// Diagnóstico estable; nulo para resultados exitosos o logs antiguos.
  final String? errorCategory;
  final String? recoveryHint;
  final int? exitCode;

  @override
  String get eventType => 'tool/result';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'callId': callId,
        'name': name,
        'content': content,
        'isError': isError,
        'durationMs': durationMs,
        'truncated': truncated,
        if (errorCategory != null) 'errorCategory': errorCategory,
        if (recoveryHint != null) 'recoveryHint': recoveryHint,
        if (exitCode != null) 'exitCode': exitCode,
      };

  static ToolResultEvent fromJson(final Map<String, Object?> j) =>
      ToolResultEvent(
        callId: (j['callId'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        content: (j['content'] as String?) ?? '',
        isError: (j['isError'] as bool?) ?? false,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        truncated: (j['truncated'] as bool?) ?? false,
        errorCategory: j['errorCategory'] as String?,
        recoveryHint: j['recoveryHint'] as String?,
        exitCode: (j['exitCode'] as num?)?.toInt(),
      );
}

/// Decisión del usuario sobre una acción propuesta.
class ApprovalDecisionEvent extends SessionEvent {
  const ApprovalDecisionEvent({
    required this.callId,
    required this.approved,
    this.rememberForSession = false,
  });

  final String callId;
  final bool approved;

  /// `true` si el usuario marcó "no volver a preguntar para esta herramienta".
  final bool rememberForSession;

  @override
  String get eventType => 'approval/decision';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'callId': callId,
        'approved': approved,
        'rememberForSession': rememberForSession,
      };

  static ApprovalDecisionEvent fromJson(final Map<String, Object?> j) =>
      ApprovalDecisionEvent(
        callId: (j['callId'] as String?) ?? '',
        approved: (j['approved'] as bool?) ?? false,
        rememberForSession: (j['rememberForSession'] as bool?) ?? false,
      );
}

/// Decisión del usuario sobre un plan propuesto con `exit_plan_mode`.
///
/// Es durable porque forma parte de la historia que ve el modelo: si el plan
/// se aprobó, el modelo debe saber que tiene permiso para actuar.
class PlanDecisionEvent extends SessionEvent {
  const PlanDecisionEvent({required this.callId, required this.approved});

  final String callId;
  final bool approved;

  @override
  String get eventType => 'plan/decision';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'callId': callId,
        'approved': approved,
      };

  static PlanDecisionEvent fromJson(final Map<String, Object?> j) =>
      PlanDecisionEvent(
        callId: (j['callId'] as String?) ?? '',
        approved: (j['approved'] as bool?) ?? false,
      );
}

/// Compactación de contexto (equivalente a `/compact` de dsh).
class CompactionEvent extends SessionEvent {
  const CompactionEvent({
    required this.summary,
    required this.replacedEventCount,
    required this.tokensBefore,
    required this.tokensAfter,
  });

  final String summary;
  final int replacedEventCount;
  final int tokensBefore;
  final int tokensAfter;

  @override
  String get eventType => 'compaction';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'summary': summary,
        'replacedEventCount': replacedEventCount,
        'tokensBefore': tokensBefore,
        'tokensAfter': tokensAfter,
      };

  static CompactionEvent fromJson(final Map<String, Object?> j) =>
      CompactionEvent(
        summary: (j['summary'] as String?) ?? '',
        replacedEventCount: (j['replacedEventCount'] as num?)?.toInt() ?? 0,
        tokensBefore: (j['tokensBefore'] as num?)?.toInt() ?? 0,
        tokensAfter: (j['tokensAfter'] as num?)?.toInt() ?? 0,
      );
}

// ---------------------------------------------------------------------------
// Eventos efímeros (solo UI, nunca al log)
// ---------------------------------------------------------------------------

/// Un fragmento de texto del modelo, según llega del stream.
class AssistantDeltaEvent extends AgentEvent {
  const AssistantDeltaEvent(this.text);
  final String text;
}

/// Un fragmento de razonamiento, según llega del stream.
class ReasoningDeltaEvent extends AgentEvent {
  const ReasoningDeltaEvent(this.text);
  final String text;
}

/// Limpia el razonamiento efímero al iniciar o terminar un turno.
class ReasoningResetEvent extends AgentEvent {
  const ReasoningResetEvent();
}

/// La herramienta empezó a ejecutarse.
class ToolStartedEvent extends AgentEvent {
  const ToolStartedEvent({required this.callId, required this.name});
  final String callId;
  final String name;
}

/// Se pide aprobación al usuario; el motor queda bloqueado hasta la respuesta.
class ApprovalRequestedEvent extends AgentEvent {
  const ApprovalRequestedEvent({
    required this.callId,
    required this.toolName,
    required this.preview,
    this.diff,
  });

  final String callId;
  final String toolName;

  /// Texto a mostrar (comando, ruta, resumen).
  final String preview;

  /// Diff unificado, para escrituras y ediciones.
  final String? diff;
}

/// El modelo presentó un plan con `exit_plan_mode` y espera una decisión.
/// Este evento es efímero; la respuesta se guarda como [PlanDecisionEvent].
class PlanProposedEvent extends AgentEvent {
  const PlanProposedEvent({required this.callId, required this.plan});

  final String callId;
  final String plan;
}

/// Estado de uso de tokens de la sesión.
class UsageEvent extends AgentEvent {
  const UsageEvent({
    required this.inputTokens,
    required this.outputTokens,
    this.cachedInputTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;

  int get total => inputTokens + outputTokens;

  /// Tasa de acierto de caché, métrica que dsh muestra en su panel.
  double get cacheHitRate =>
      inputTokens == 0 ? 0 : cachedInputTokens / inputTokens;
}

/// Error del motor, ya traducido a lenguaje humano.
class AgentErrorEvent extends AgentEvent {
  const AgentErrorEvent({required this.message, this.isRetryable = false});
  final String message;
  final bool isRetryable;
}
