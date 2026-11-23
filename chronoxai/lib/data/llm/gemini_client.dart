import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/llm/llm_types.dart';

/// Adaptador de Gemini `streamGenerateContent` con function calling.
class GeminiClient implements LlmProvider {
  GeminiClient({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://generativelanguage.googleapis.com',
    this.contextWindow,
    this.timeout = const Duration(seconds: 180),
    http.Client Function()? clientFactory,
  }) : _newClient = clientFactory ?? http.Client.new;

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final http.Client Function() _newClient;

  @override
  final String model;
  @override
  final int? contextWindow;
  @override
  String get name => 'Google Gemini';

  @override
  Stream<LlmChunk> stream({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    final double? temperature,
    final int? maxTokens,
  }) {
    final system = messages
        .where((final message) => message.role == MessageRole.system)
        .map((final message) => message.content)
        .join('\n\n');
    final body = <String, Object?>{
      if (system.isNotEmpty)
        'systemInstruction': <String, Object?>{
          'parts': <Object?>[<String, Object?>{'text': system}],
        },
      'contents': _contents(messages),
      if (tools.isNotEmpty)
        'tools': <Object?>[
          <String, Object?>{
            'functionDeclarations': tools.map(_function).toList(),
          }
        ],
      if (temperature != null || maxTokens != null)
        'generationConfig': <String, Object?>{
          if (temperature != null) 'temperature': temperature,
          if (maxTokens != null) 'maxOutputTokens': maxTokens,
        },
    };

    late StreamController<LlmChunk> controller;
    http.Client? client;
    StreamSubscription<String>? subscription;
    var inputTokens = 0;
    var outputTokens = 0;
    var nextToolIndex = 0;
    String? stopReason;

    controller = StreamController<LlmChunk>(
      onListen: () async {
        try {
          client = _newClient();
          final root = baseUrl.replaceFirst(RegExp(r'/$'), '');
          final uri = Uri.parse('$root/v1beta/models/$model:streamGenerateContent')
              .replace(queryParameters: <String, String>{'alt': 'sse', 'key': apiKey});
          final request = http.Request('POST', uri)
            ..headers.addAll(const <String, String>{
              'content-type': 'application/json',
              'accept': 'text/event-stream',
            })
            ..body = jsonEncode(body);
          final response = await client!.send(request).timeout(timeout);
          if (response.statusCode >= 400) {
            final error = await response.stream.bytesToString();
            throw LlmException(
              response.statusCode == 401 || response.statusCode == 403
                  ? LlmErrorKind.auth
                  : response.statusCode == 429
                      ? LlmErrorKind.rateLimit
                      : response.statusCode >= 500
                          ? LlmErrorKind.server
                          : LlmErrorKind.unknown,
              error,
              statusCode: response.statusCode,
            );
          }
          subscription = response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((final line) {
            if (!line.startsWith('data:')) return;
            final payload = line.substring(5).trim();
            if (payload.isEmpty || payload == '[DONE]') return;
            final json = jsonDecode(payload) as Map<String, Object?>;
            final candidates = json['candidates'] as List<Object?>? ?? const [];
            if (candidates.isNotEmpty) {
              final candidate = candidates.first as Map<String, Object?>;
              final finish = candidate['finishReason'] as String?;
              if (finish != null) stopReason = finish;
              final content = candidate['content'] as Map<String, Object?>?;
              final parts = content?['parts'] as List<Object?>? ?? const [];
              for (final rawPart in parts) {
                final part = rawPart as Map<String, Object?>;
                final text = part['text'];
                if (text is String && text.isNotEmpty) controller.add(TextChunk(text));
                final call = part['functionCall'] as Map<String, Object?>?;
                if (call != null) {
                  final args = call['args'] as Map<String, Object?>? ?? const {};
                  controller.add(ToolCallChunk(
                    index: nextToolIndex,
                    id: 'gemini-${nextToolIndex++}',
                    name: (call['name'] as String?) ?? '',
                    argumentsFragment: jsonEncode(args),
                  ));
                }
              }
            }
            final usage = json['usageMetadata'] as Map<String, Object?>?;
            inputTokens = (usage?['promptTokenCount'] as num?)?.toInt() ?? inputTokens;
            outputTokens = (usage?['candidatesTokenCount'] as num?)?.toInt() ?? outputTokens;
          }, onError: (final Object error, final StackTrace stack) {
            controller.addError(error, stack);
          }, onDone: () {
            if (controller.isClosed) return;
            controller
              ..add(DoneChunk(
                usage: LlmUsage(inputTokens: inputTokens, outputTokens: outputTokens),
                stopReason: stopReason,
              ))
              ..close();
          });
        } catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
          if (!controller.isClosed) await controller.close();
        }
      },
      onCancel: () async {
        await subscription?.cancel();
        client?.close();
      },
    );
    return controller.stream;
  }

  static List<Map<String, Object?>> _contents(final List<LlmMessage> messages) {
    final output = <Map<String, Object?>>[];
    final toolNames = <String, String>{
      for (final message in messages)
        for (final call in message.toolCalls) call.id: call.name,
    };
    for (final message in messages) {
      if (message.role == MessageRole.system) continue;
      if (message.role == MessageRole.tool) {
        output.add(<String, Object?>{
          'role': 'user',
          'parts': <Object?>[
            <String, Object?>{
              'functionResponse': <String, Object?>{
                'name': toolNames[message.toolCallId] ?? 'tool',
                'response': <String, Object?>{'content': message.content},
              }
            }
          ],
        });
      } else if (message.role == MessageRole.assistant && message.toolCalls.isNotEmpty) {
        output.add(<String, Object?>{
          'role': 'model',
          'parts': <Object?>[
            if (message.content.isNotEmpty) <String, Object?>{'text': message.content},
            for (final call in message.toolCalls)
              <String, Object?>{
                'functionCall': <String, Object?>{
                  'name': call.name,
                  'args': call.arguments,
                }
              },
          ],
        });
      } else {
        output.add(<String, Object?>{
          'role': message.role == MessageRole.assistant ? 'model' : 'user',
          'parts': <Object?>[<String, Object?>{'text': message.content}],
        });
      }
    }
    return output;
  }

  static Map<String, Object?> _function(final Map<String, Object?> tool) {
    final function = tool['function'] as Map<String, Object?>? ?? tool;
    return <String, Object?>{
      'name': function['name'],
      'description': function['description'] ?? '',
      'parameters': function['parameters'] ?? <String, Object?>{'type': 'object'},
    };
  }
}
