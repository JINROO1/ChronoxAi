import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/llm/llm_types.dart';

/// Adaptador de Messages API de Anthropic con streaming SSE y tool_use.
class AnthropicClient implements LlmProvider {
  AnthropicClient({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://api.anthropic.com',
    this.contextWindow = 200000,
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
  String get name => 'Anthropic';

  @override
  Stream<LlmChunk> stream({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    final double? temperature,
    final int? maxTokens,
  }) {
    final system = messages
        .where((final m) => m.role == MessageRole.system)
        .map((final m) => m.content)
        .join('\n\n');
    final body = <String, Object?>{
      'model': model,
      'max_tokens': maxTokens ?? 4096,
      'stream': true,
      if (system.isNotEmpty) 'system': system,
      'messages': _messages(messages),
      if (tools.isNotEmpty) 'tools': tools.map(_tool).toList(),
      if (temperature != null) 'temperature': temperature,
    };

    late StreamController<LlmChunk> controller;
    http.Client? client;
    StreamSubscription<String>? subscription;
    final blocks = <int, _AnthropicToolBuffer>{};
    var inputTokens = 0;
    var outputTokens = 0;
    var stopReason = '';

    controller = StreamController<LlmChunk>(
      onListen: () async {
        try {
          client = _newClient();
          final uri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/$'), '')}/v1/messages');
          final request = http.Request('POST', uri)
            ..headers.addAll(<String, String>{
              'content-type': 'application/json',
              'accept': 'text/event-stream',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
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
          String? eventName;
          subscription = response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((final line) {
            if (line.startsWith('event:')) {
              eventName = line.substring(6).trim();
              return;
            }
            if (!line.startsWith('data:')) return;
            final data = line.substring(5).trim();
            if (data.isEmpty || data == '[DONE]') return;
            final json = jsonDecode(data) as Map<String, Object?>;
            switch (eventName ?? json['type']) {
              case 'content_block_start':
                final index = (json['index'] as num?)?.toInt() ?? 0;
                final block = json['content_block'] as Map<String, Object?>?;
                if (block?['type'] == 'tool_use') {
                  blocks[index] = _AnthropicToolBuffer(
                    id: (block?['id'] as String?) ?? 'tool-$index',
                    name: (block?['name'] as String?) ?? '',
                  );
                }
              case 'content_block_delta':
                final index = (json['index'] as num?)?.toInt() ?? 0;
                final delta = json['delta'] as Map<String, Object?>?;
                if (delta?['type'] == 'text_delta') {
                  controller.add(TextChunk((delta?['text'] as String?) ?? ''));
                } else if (delta?['type'] == 'input_json_delta') {
                  blocks[index]?.arguments.write(delta?['partial_json'] ?? '');
                }
              case 'message_delta':
                final delta = json['delta'] as Map<String, Object?>?;
                stopReason = (delta?['stop_reason'] as String?) ?? stopReason;
                final usage = json['usage'] as Map<String, Object?>?;
                outputTokens = (usage?['output_tokens'] as num?)?.toInt() ?? outputTokens;
              case 'message_start':
                final message = json['message'] as Map<String, Object?>?;
                final usage = message?['usage'] as Map<String, Object?>?;
                inputTokens = (usage?['input_tokens'] as num?)?.toInt() ?? inputTokens;
              case 'message_stop':
                for (final entry in blocks.entries) {
                  final buffer = entry.value;
                  controller.add(ToolCallChunk(
                    index: entry.key,
                    id: buffer.id,
                    name: buffer.name,
                    argumentsFragment: buffer.arguments.toString(),
                  ));
                }
                controller.add(DoneChunk(
                  usage: LlmUsage(inputTokens: inputTokens, outputTokens: outputTokens),
                  stopReason: stopReason,
                ));
              default:
                break;
            }
          }, onError: (final Object error, final StackTrace stack) {
            controller.addError(error, stack);
          }, onDone: () {
            if (!controller.isClosed) controller.close();
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

  static List<Map<String, Object?>> _messages(final List<LlmMessage> messages) {
    final output = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message.role == MessageRole.system) continue;
      if (message.role == MessageRole.tool) {
        output.add(<String, Object?>{
          'role': 'user',
          'content': <Object?>[
            <String, Object?>{
              'type': 'tool_result',
              'tool_use_id': message.toolCallId ?? '',
              'content': message.content,
            }
          ],
        });
      } else if (message.role == MessageRole.assistant && message.toolCalls.isNotEmpty) {
        output.add(<String, Object?>{
          'role': 'assistant',
          'content': <Object?>[
            if (message.content.isNotEmpty)
              <String, Object?>{'type': 'text', 'text': message.content},
            for (final call in message.toolCalls)
              <String, Object?>{
                'type': 'tool_use',
                'id': call.id,
                'name': call.name,
                'input': call.arguments,
              },
          ],
        });
      } else {
        output.add(<String, Object?>{
          'role': message.role == MessageRole.assistant ? 'assistant' : 'user',
          'content': message.content,
        });
      }
    }
    return output;
  }

  static Map<String, Object?> _tool(final Map<String, Object?> openAiTool) {
    final function = openAiTool['function'] as Map<String, Object?>? ?? openAiTool;
    return <String, Object?>{
      'name': function['name'],
      'description': function['description'] ?? '',
      'input_schema': function['parameters'] ?? <String, Object?>{'type': 'object'},
    };
  }
}

class _AnthropicToolBuffer {
  _AnthropicToolBuffer({required this.id, required this.name});
  final String id;
  final String name;
  final StringBuffer arguments = StringBuffer();
}
