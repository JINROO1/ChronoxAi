import 'dart:async';
import 'dart:convert';

/// Roles de un mensaje en la conversación.
enum MessageRole { system, user, assistant, tool }

/// Un mensaje en el formato que consumen los proveedores.
///
/// Es una representación **neutral**: cada adaptador (OpenAI, Anthropic…) la
/// traduce a su propio JSON. Así el motor no conoce ningún proveedor concreto.
class LlmMessage {
  const LlmMessage({
    required this.role,
    this.content = '',
    this.toolCallId,
    this.toolCalls = const <LlmToolCall>[],
    this.reasoning,
  });

  const LlmMessage.system(this.content)
      : role = MessageRole.system,
        toolCallId = null,
        toolCalls = const <LlmToolCall>[],
        reasoning = null;

  const LlmMessage.user(this.content)
      : role = MessageRole.user,
        toolCallId = null,
        toolCalls = const <LlmToolCall>[],
        reasoning = null;

  const LlmMessage.assistant(
    this.content, {
    this.toolCalls = const <LlmToolCall>[],
    this.reasoning,
  })  : role = MessageRole.assistant,
        toolCallId = null;

  const LlmMessage.toolResult({
    required this.toolCallId,
    required this.content,
  })  : role = MessageRole.tool,
        toolCalls = const <LlmToolCall>[],
        reasoning = null;

  final MessageRole role;
  final String content;

  /// Solo para [MessageRole.tool]: id de la llamada que se responde.
  final String? toolCallId;

  /// Solo para [MessageRole.assistant]: herramientas que el modelo quiere usar.
  final List<LlmToolCall> toolCalls;

  /// Razonamiento del modelo, si el proveedor lo expone (DeepSeek `reasoning`).
  final String? reasoning;

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role.name,
        'content': content,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((final c) => c.toJson()).toList(),
      };
}

/// Una llamada a herramienta pedida por el modelo.
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.parseError,
  });

  final String id;
  final String name;

  /// Argumentos ya decodificados. Si el modelo manda JSON inválido, el adaptador
  /// devuelve un mapa vacío y deja el error en [parseError] para que el motor
  /// pueda pedir una corrección en lugar de fallar.
  final Map<String, Object?> arguments;

  final String? parseError;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'type': 'function',
        'function': <String, Object?>{
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      };
}

/// Uso de tokens de una respuesta.
class LlmUsage {
  const LlmUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;

  int get total => inputTokens + outputTokens;
}

/// Respuesta completa del modelo.
class LlmResponse {
  const LlmResponse({
    required this.content,
    this.toolCalls = const <LlmToolCall>[],
    this.reasoning,
    this.usage = const LlmUsage(),
    this.stopReason,
  });

  final String content;
  final List<LlmToolCall> toolCalls;
  final String? reasoning;
  final LlmUsage usage;

  /// `stop`, `tool_calls`, `length`, `content_filter`…
  final String? stopReason;

  bool get wantsTools => toolCalls.isNotEmpty;
}

/// Un fragmento del stream.
sealed class LlmChunk {
  const LlmChunk();
}

/// Texto incremental.
class TextChunk extends LlmChunk {
  const TextChunk(this.text);
  final String text;
}

/// Razonamiento incremental (DeepSeek `reasoning_content`).
class ReasoningChunk extends LlmChunk {
  const ReasoningChunk(this.text);
  final String text;
}

/// Fragmento de una llamada a herramienta (los argumentos llegan troceados).
class ToolCallChunk extends LlmChunk {
  const ToolCallChunk({
    required this.index,
    this.id,
    this.name,
    this.argumentsFragment,
  });

  final int index;
  final String? id;
  final String? name;
  final String? argumentsFragment;
}

/// Fin del stream, con métricas.
class DoneChunk extends LlmChunk {
  const DoneChunk({this.usage = const LlmUsage(), this.stopReason});
  final LlmUsage usage;
  final String? stopReason;
}

/// Error de un proveedor, ya clasificado.
///
/// La distinción importa: un 429 se reintenta con espera, un 401 no (el usuario
/// debe arreglar la clave), y un contexto excedido necesita compactación.
enum LlmErrorKind {
  /// Clave ausente o inválida: no reintentar, avisar al usuario.
  auth,

  /// Límite de peticiones: reintentar con backoff.
  rateLimit,

  /// El contexto no cabe: compactar y reintentar.
  contextLength,

  /// Red caída o timeout: reintentar.
  network,

  /// Error del servidor: reintentar.
  server,

  /// Cualquier otra cosa.
  unknown,
}

class LlmException implements Exception {
  const LlmException(this.kind, this.message,
      {this.statusCode, this.retryAfter});

  final LlmErrorKind kind;
  final String message;
  final int? statusCode;

  /// Espera sugerida por el servidor (`Retry-After`).
  final Duration? retryAfter;

  bool get isRetryable => switch (kind) {
        LlmErrorKind.rateLimit ||
        LlmErrorKind.network ||
        LlmErrorKind.server =>
          true,
        LlmErrorKind.auth || LlmErrorKind.contextLength => false,
        LlmErrorKind.unknown => false,
      };

  @override
  String toString() => 'LlmException(${kind.name}): $message';
}

/// Contrato de un proveedor de modelos.
///
/// Equivalente a `ctx.llm` de DeepSeek Harness: un *seam* que se puede sustituir
/// por otro proveedor sin tocar el motor.
abstract class LlmProvider {
  /// Nombre legible, para Ajustes.
  String get name;

  /// Identificador del modelo activo.
  String get model;

  /// Presupuesto de contexto en tokens, si el proveedor lo declara.
  int? get contextWindow;

  /// Envía una petición y devuelve el stream de fragmentos.
  ///
  /// Cancelar la suscripción **debe** abortar la petición HTTP en curso: en
  /// móvil, dejar peticiones huérfanas consume batería y datos.
  Stream<LlmChunk> stream({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  });
}
