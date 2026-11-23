import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/llm/llm_types.dart';

/// Cliente para cualquier API compatible con OpenAI (`/chat/completions`).
///
/// Sirve para DeepSeek, OpenRouter, Groq, Together, vLLM, Ollama y LM Studio.
/// La diferencia entre ellos es la `baseUrl` y la clave.
///
/// Lo delicado aquí es el ensamblado de `tool_calls`: la API los envía
/// **troceados** por índice y en fragmentos de JSON que no son parseables hasta
/// que llega el último. Interpretarlos por fragmento produce errores
/// intermitentes difíciles de diagnosticar, así que se acumulan por índice y
/// solo se decodifican al cerrar el stream.
class OpenAiCompatibleClient implements LlmProvider {
  OpenAiCompatibleClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.name = 'OpenAI-compatible',
    this.contextWindow,
    this.organization,
    this.timeout = const Duration(seconds: 180),
    http.Client Function()? clientFactory,
  }) : _newClient = clientFactory ?? http.Client.new;

  final String baseUrl;
  final String apiKey;

  @override
  final String model;

  @override
  final String name;

  @override
  final int? contextWindow;

  final String? organization;
  final Duration timeout;

  /// Fábrica de clientes HTTP. Cada petición usa **su propio** cliente para que
  /// cancelar aborte esa conexión y no las demás. Inyectable para las pruebas.
  final http.Client Function() _newClient;

  Uri get _endpoint {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    // Tolerar que el usuario pegue la URL con o sin /v1.
    final path = base.endsWith('/v1') || base.contains('/chat/completions')
        ? '/chat/completions'
        : '/v1/chat/completions';
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers => <String, String>{
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    if (organization != null) 'OpenAI-Organization': organization!,
  };

  @override
  Stream<LlmChunk> stream({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    final double? temperature,
    final int? maxTokens,
  }) {
    final body = <String, Object?>{
      'model': model,
      'messages': messages.map((final m) => m.toJson()).toList(),
      'stream': true,
      // Muchos proveedores solo envían el uso de tokens si se pide.
      'stream_options': <String, Object?>{'include_usage': true},
      if (tools.isNotEmpty) 'tools': tools,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
    };

    late StreamController<LlmChunk> controller;
    http.Client? requestClient;
    StreamSubscription<String>? lineSubscription;

    Future<void> cancel() async {
      await lineSubscription?.cancel();
      requestClient?.close();
    }

    controller = StreamController<LlmChunk>(
      onListen: () async {
        // Buffer de tool_calls por índice, acumulado entre fragmentos.
        final pending = <int, _ToolCallBuffer>{};
        var usage = const LlmUsage();
        String? stopReason;

        try {
          final client = _newClient();
          requestClient = client;
          if (controller.isClosed) {
            client.close();
            return;
          }
          final request = http.Request('POST', _endpoint)
            ..headers.addAll(_headers)
            ..body = jsonEncode(body);

          final response = await client.send(request).timeout(timeout);

          if (response.statusCode >= 400) {
            final errorBody = await response.stream.bytesToString();
            throw _classify(response.statusCode, errorBody, response.headers);
          }

          lineSubscription = response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (final line) {
                  if (controller.isClosed) return;
                  final trimmed = line.trim();
                  if (trimmed.isEmpty || trimmed.startsWith(':')) return;

                  if (!trimmed.startsWith('data:')) {
                    // Algunos proveedores mandan líneas `event:` que se ignoran.
                    return;
                  }
                  final payload = trimmed.substring(5).trim();
                  if (payload == '[DONE]') return;

                  try {
                    final json =
                        jsonDecode(payload) as Map<String, Object?>;
                    _handleChunk(json, controller, pending, (final u) => usage = u,
                        (final r) => stopReason = r);
                  } on FormatException {
                    // Un fragmento malformado no debe matar el stream: algunos
                    // proveedores intercalan keep-alives no JSON.
                  }
                },
                onError: (final Object error) {
                  if (!controller.isClosed) {
                    controller.addError(_asLlmException(error));
                    unawaited(controller.close());
                  }
                },
                onDone: () {
                  if (controller.isClosed) return;
                  // Cierre: ahora sí se pueden decodificar los argumentos.
                  for (final entry in pending.values) {
                    final call = entry.build();
                    if (call != null) {
                      controller.add(
                        ToolCallChunk(
                          index: entry.index,
                          id: call.id,
                          name: call.name,
                          argumentsFragment: jsonEncode(call.arguments),
                        ),
                      );
                    }
                  }
                  controller.add(DoneChunk(usage: usage, stopReason: stopReason));
                  unawaited(controller.close());
                },
                cancelOnError: true,
              );
        } catch (error) {
          if (!controller.isClosed) {
            controller.addError(_asLlmException(error));
            await controller.close();
          }
        }
      },
      onCancel: cancel,
    );

    return controller.stream;
  }

  void _handleChunk(
    final Map<String, Object?> json,
    final StreamController<LlmChunk> controller,
    final Map<int, _ToolCallBuffer> pending,
    final void Function(LlmUsage) setUsage,
    final void Function(String?) setStopReason,
  ) {
    final usageJson = json['usage'];
    if (usageJson is Map<String, Object?>) {
      setUsage(
        LlmUsage(
          inputTokens: (usageJson['prompt_tokens'] as num?)?.toInt() ?? 0,
          outputTokens: (usageJson['completion_tokens'] as num?)?.toInt() ?? 0,
          cachedInputTokens:
              (usageJson['prompt_tokens_details'] as Map<String, Object?>?)?['cached_tokens']
                  as int? ??
              0,
        ),
      );
    }

    final choices = json['choices'];
    if (choices is! List<Object?> || choices.isEmpty) return;
    final choice = choices.first;
    if (choice is! Map<String, Object?>) return;

    final finish = choice['finish_reason'] as String?;
    if (finish != null) setStopReason(finish);

    final delta = choice['delta'];
    if (delta is! Map<String, Object?>) return;

    final content = delta['content'];
    if (content is String && content.isNotEmpty) {
      controller.add(TextChunk(content));
    }

    // DeepSeek expone el razonamiento en `reasoning_content`.
    final reasoning =
        delta['reasoning_content'] ?? delta['reasoning'];
    if (reasoning is String && reasoning.isNotEmpty) {
      controller.add(ReasoningChunk(reasoning));
    }

    final toolCalls = delta['tool_calls'];
    if (toolCalls is! List<Object?>) return;

    for (final raw in toolCalls) {
      if (raw is! Map<String, Object?>) continue;
      final index = (raw['index'] as num?)?.toInt() ?? 0;
      final buffer = pending.putIfAbsent(index, () => _ToolCallBuffer(index));

      final id = raw['id'];
      if (id is String && id.isNotEmpty) buffer.id = id;

      final function = raw['function'];
      if (function is Map<String, Object?>) {
        final fnName = function['name'];
        if (fnName is String && fnName.isNotEmpty) buffer.name = fnName;
        final args = function['arguments'];
        if (args is String) buffer.arguments.write(args);
      }

      // Deliberadamente **no** se emite aquí: los argumentos aún no son JSON
      // válido y emitirlos haría que el consumidor decodificara un fragmento
      // parcial. Se emite una sola vez, ya ensamblado, al cerrar el stream.
    }
  }

  static LlmException _classify(
    final int status,
    final String body,
    final Map<String, String> headers,
  ) {
    final kind = switch (status) {
      401 || 403 => LlmErrorKind.auth,
      429 => LlmErrorKind.rateLimit,
      400 || 413 => _looksLikeContextOverflow(body)
          ? LlmErrorKind.contextLength
          : LlmErrorKind.unknown,
      >= 500 => LlmErrorKind.server,
      _ => LlmErrorKind.unknown,
    };

    Duration? retryAfter;
    final header = headers['retry-after'];
    if (header != null) {
      final seconds = int.tryParse(header);
      if (seconds != null) retryAfter = Duration(seconds: seconds);
    }

    return LlmException(
      kind,
      _humanMessage(kind, status, body),
      statusCode: status,
      retryAfter: retryAfter,
    );
  }

  static bool _looksLikeContextOverflow(final String body) {
    final lower = body.toLowerCase();
    return lower.contains('context') &&
        (lower.contains('length') ||
            lower.contains('too long') ||
            lower.contains('maximum'));
  }

  /// Convierte el error del proveedor en algo que el usuario pueda accionar.
  static String _humanMessage(
    final LlmErrorKind kind,
    final int status,
    final String body,
  ) {
    final detail = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    return switch (kind) {
      LlmErrorKind.auth =>
        'La clave de API no es válida o no tiene permiso (HTTP $status). '
            'Revísala en Ajustes → Proveedor.',
      LlmErrorKind.rateLimit =>
        'El proveedor limita las peticiones (HTTP 429). Se reintentará '
            'automáticamente.',
      LlmErrorKind.contextLength =>
        'La conversación es demasiado larga para el modelo (HTTP $status). '
            'Se compactará el contexto.',
      LlmErrorKind.server =>
        'El proveedor falló (HTTP $status). Se reintentará.',
      LlmErrorKind.network => 'No se pudo conectar con el proveedor.',
      LlmErrorKind.unknown => 'Error del proveedor (HTTP $status): $detail',
    };
  }

  static LlmException _asLlmException(final Object error) {
    if (error is LlmException) return error;
    if (error is TimeoutException) {
      return const LlmException(
        LlmErrorKind.network,
        'El proveedor no respondió a tiempo.',
      );
    }
    return LlmException(
      LlmErrorKind.network,
      'Error de red: $error',
    );
  }

}

/// Acumula los fragmentos de una `tool_call` hasta poder decodificarla.
class _ToolCallBuffer {
  _ToolCallBuffer(this.index);

  final int index;
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  LlmToolCall? build() {
    final callName = name;
    // Nombre ausente = la llamada no se puede ejecutar; se descarta y el modelo
    // verá que no hubo resultado.
    if (callName == null) return null;
    // El id puede faltar en proveedores no estándar: se sintetiza uno estable
    // para que el mensaje `tool` posterior siga siendo válido.
    final callId = id ?? 'call_$index';

    final raw = arguments.toString().trim();
    if (raw.isEmpty) {
      return LlmToolCall(id: callId, name: callName, arguments: const <String, Object?>{});
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return LlmToolCall(id: callId, name: callName, arguments: decoded);
      }
      return LlmToolCall(
        id: callId,
        name: callName,
        arguments: const <String, Object?>{},
        parseError: 'Los argumentos no son un objeto JSON: $raw',
      );
    } on FormatException catch (e) {
      return LlmToolCall(
        id: callId,
        name: callName,
        arguments: const <String, Object?>{},
        parseError: 'JSON inválido en los argumentos ($e). Recibido: $raw',
      );
    }
  }
}
