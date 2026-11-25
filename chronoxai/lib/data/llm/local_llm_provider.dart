import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/llm/llm_types.dart';

/// Narrow seam between ChronoxAI's LLM contract and an on-device runtime.
///
/// Implementations must never make network requests. The eventual Android
/// implementation owns the native model/context lifetime and exposes generated
/// tokens incrementally; tests can provide a deterministic fake.
abstract interface class LocalInferenceEngine {
  String get model;
  int? get contextWindow;
  bool get isLoaded;

  Future<void> load(File modelFile);

  Stream<String> generate({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  });

  Future<void> cancel();
  Future<void> unload();
}

/// Adapts a local inference engine to the same streaming contract as remote
/// providers. It deliberately has no fallback path to a network provider.
class LocalLlmProvider implements LlmProvider {
  LocalLlmProvider(this.engine, {this.modelFileResolver});

  final LocalInferenceEngine engine;
  final Future<File?> Function()? modelFileResolver;
  bool _generating = false;

  @override
  String get name => 'Qwen local (en el dispositivo)';

  @override
  String get model => engine.model;

  @override
  int? get contextWindow => engine.contextWindow;

  Future<void> loadModel(File file) => engine.load(file);

  Future<void> unloadModel() => engine.unload();

  Future<void> dispose() async {
    await engine.cancel();
    await engine.unload();
  }

  @override
  Stream<LlmChunk> stream({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  }) {
    if (_generating) {
      return Stream<LlmChunk>.error(const LlmException(
        LlmErrorKind.unknown,
        'Ya hay una generación local en curso.',
      ));
    }

    _generating = true;
    late final StreamController<LlmChunk> controller;
    controller = StreamController<LlmChunk>(
      onListen: () async {
        try {
          if (!engine.isLoaded) {
            final file = await modelFileResolver?.call();
            if (file == null) {
              throw const LlmException(
                LlmErrorKind.unknown,
                'No hay un modelo local instalado o seleccionado.',
              );
            }
            await engine.load(file);
          }
          final request = tools.isEmpty
              ? _PreparedLocalRequest(
                  messages: _normalizeLocalHistory(messages),
                  toolNames: const <String>{},
                )
              : _prepareLocalToolRequest(messages, tools);
          final toolAware = tools.isNotEmpty;
          final pendingProtocol = StringBuffer();
          var plainText = !toolAware;
          await for (final token in engine.generate(
            messages: request.messages,
            tools: const <Map<String, Object?>>[],
            temperature: temperature,
            maxTokens: maxTokens,
          )) {
            if (token.isEmpty || controller.isClosed) continue;
            if (plainText) {
              controller.add(TextChunk(token));
              continue;
            }

            pendingProtocol.write(token);
            final candidate = pendingProtocol.toString();
            final marker = _localToolCallStart;
            if (!candidate.startsWith(marker)) {
              var prefixLength = 0;
              final maximum = candidate.length < marker.length
                  ? candidate.length
                  : marker.length - 1;
              for (var length = maximum; length > 0; length--) {
                if (candidate.endsWith(marker.substring(0, length))) {
                  prefixLength = length;
                  break;
                }
              }
              final safeLength = candidate.length - prefixLength;
              if (safeLength > 0) {
                controller.add(TextChunk(candidate.substring(0, safeLength)));
                pendingProtocol
                  ..clear()
                  ..write(candidate.substring(safeLength));
              }
            }
          }

          if (!controller.isClosed) {
            if (!plainText && pendingProtocol.isNotEmpty) {
              final response = pendingProtocol.toString();
              final call = _decodeLocalToolCall(
                response,
                request.toolNames,
              );
              if (call == null) {
                controller.add(TextChunk(response));
                controller.add(const DoneChunk());
              } else {
                controller.add(ToolCallChunk(
                  index: 0,
                  id: 'local_${DateTime.now().microsecondsSinceEpoch}',
                  name: call.name,
                  argumentsFragment: jsonEncode(call.arguments),
                ));
                controller.add(const DoneChunk(stopReason: 'tool_calls'));
              }
            } else {
              controller.add(const DoneChunk());
            }
          }
        } catch (error, stackTrace) {
          if (!controller.isClosed) controller.addError(error, stackTrace);
        } finally {
          _generating = false;
          if (!controller.isClosed) await controller.close();
        }
      },
      onCancel: () async {
        // Keep the provider busy until onListen's finally block runs. Native
        // cancellation is asynchronous; releasing the guard here could admit a
        // second request while the first JNI call still owns the context.
        await engine.cancel();
      },
    );
    return controller.stream;
  }
}

const _localToolCallStart = '<chronox-tool-call>';
const _localToolCallEnd = '</chronox-tool-call>';

class _PreparedLocalRequest {
  const _PreparedLocalRequest(
      {required this.messages, required this.toolNames});

  final List<LlmMessage> messages;
  final Set<String> toolNames;
}

class _DecodedLocalToolCall {
  const _DecodedLocalToolCall(this.name, this.arguments);

  final String name;
  final Map<String, Object?> arguments;
}

List<LlmMessage> _normalizeLocalHistory(List<LlmMessage> messages) {
  return messages.map((final message) {
    if (message.role == MessageRole.assistant && message.toolCalls.isNotEmpty) {
      final calls = message.toolCalls
          .map((final call) => <String, Object?>{
                'id': call.id,
                'name': call.name,
                'arguments': call.arguments,
              })
          .toList();
      final record =
          '<tool-call-history>${jsonEncode(calls)}</tool-call-history>';
      return LlmMessage.assistant(
        message.content.isEmpty ? record : '${message.content}\n$record',
        reasoning: message.reasoning,
      );
    }
    if (message.role == MessageRole.tool) {
      return LlmMessage.user(
        '<tool-result id="${message.toolCallId ?? 'sin ID'}">\n'
        '${message.content}\n</tool-result>',
      );
    }
    return message;
  }).toList(growable: false);
}

_PreparedLocalRequest _prepareLocalToolRequest(
  List<LlmMessage> messages,
  List<Map<String, Object?>> tools,
) {
  final declarations = <Map<String, Object?>>[];
  final names = <String>{};
  for (final tool in tools) {
    final rawFunction = tool['function'];
    final function =
        rawFunction is Map ? Map<String, Object?>.from(rawFunction) : tool;
    final name = function['name'];
    if (name is! String || name.isEmpty || !names.add(name)) {
      throw const LlmException(
        LlmErrorKind.unknown,
        'El catálogo local de herramientas contiene un nombre inválido o repetido.',
      );
    }
    declarations.add(<String, Object?>{
      'name': name,
      'description': function['description']?.toString() ?? '',
      'parameters': function['parameters'] is Map
          ? Map<String, Object?>.from(function['parameters'] as Map)
          : <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{}
            },
    });
  }

  final instruction = '''
Herramientas locales disponibles (solo solicitud; nunca ejecutes nada tú):
${jsonEncode(declarations)}

Si una herramienta es necesaria, responde únicamente con este formato exacto:
$_localToolCallStart{"name":"nombre_exacto","arguments":{}}$_localToolCallEnd
Usa un solo objeto JSON válido, nombre de la lista y argumentos que cumplan su esquema. No agregues texto antes ni después. Si no necesitas herramientas, responde normalmente. El sistema validará la solicitud y aplicará sus permisos/aprobaciones antes de ejecutar.
''';
  var inserted = false;
  final prepared = <LlmMessage>[];
  for (final message in _normalizeLocalHistory(messages)) {
    if (!inserted && message.role == MessageRole.system) {
      prepared.add(LlmMessage.system('${message.content}\n\n$instruction'));
      inserted = true;
    } else {
      prepared.add(message);
    }
  }
  if (!inserted) prepared.insert(0, LlmMessage.system(instruction));
  return _PreparedLocalRequest(messages: prepared, toolNames: names);
}

_DecodedLocalToolCall? _decodeLocalToolCall(
  String raw,
  Set<String> allowedNames,
) {
  final response = raw.trim();
  if (!response.startsWith(_localToolCallStart) ||
      !response.endsWith(_localToolCallEnd)) {
    return null;
  }
  final json = response.substring(
    _localToolCallStart.length,
    response.length - _localToolCallEnd.length,
  );
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name'];
    final rawArguments = decoded['arguments'];
    if (name is! String ||
        !allowedNames.contains(name) ||
        rawArguments is! Map<String, dynamic>) {
      return null;
    }
    return _DecodedLocalToolCall(
      name,
      Map<String, Object?>.from(rawArguments),
    );
  } on FormatException {
    return null;
  }
}
