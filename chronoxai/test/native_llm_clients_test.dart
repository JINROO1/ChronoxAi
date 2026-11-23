import 'dart:convert';

import 'package:chronoxai/data/llm/anthropic_client.dart';
import 'package:chronoxai/data/llm/gemini_client.dart';
import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Transport extends http.BaseClient {
  _Transport(this.payload);
  final String payload;
  http.BaseRequest? request;

  @override
  Future<http.StreamedResponse> send(final http.BaseRequest request) async {
    this.request = request;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(payload)),
      200,
      request: request,
    );
  }

  @override
  void close() {}
}

const _tools = <Map<String, Object?>>[
  <String, Object?>{
    'type': 'function',
    'function': <String, Object?>{
      'name': 'read_file',
      'description': 'Read a file',
      'parameters': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{'path': <String, Object?>{'type': 'string'}},
        'required': <String>['path'],
      },
    },
  },
];

void main() {
  test('Anthropic maps messages/tools and streams text and tool input', () async {
    final transport = _Transport([
      'event: message_start\ndata: {"message":{"usage":{"input_tokens":8}}}\n\n',
      'event: content_block_start\ndata: {"index":0,"content_block":{"type":"text","text":""}}\n\n',
      'event: content_block_delta\ndata: {"index":0,"delta":{"type":"text_delta","text":"Hello"}}\n\n',
      'event: content_block_start\ndata: {"index":1,"content_block":{"type":"tool_use","id":"tu1","name":"read_file","input":{}}}\n\n',
      'event: content_block_delta\ndata: {"index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"a.txt\\"}"}}\n\n',
      'event: message_stop\ndata: {}\n\n',
    ].join());
    final client = AnthropicClient(
      apiKey: 'secret',
      model: 'claude-test',
      clientFactory: () => transport,
    );

    final chunks = await client.stream(
      messages: const <LlmMessage>[LlmMessage.system('rules'), LlmMessage.user('hi')],
      tools: _tools,
    ).toList();

    expect(chunks.whereType<TextChunk>().single.text, 'Hello');
    final tool = chunks.whereType<ToolCallChunk>().single;
    expect(tool.name, 'read_file');
    expect(tool.id, 'tu1');
    expect(transport.request!.url.path, '/v1/messages');
    expect(transport.request!.headers['anthropic-version'], '2023-06-01');
    final body = jsonDecode((transport.request! as http.Request).body) as Map<String, Object?>;
    expect(body['system'], 'rules');
    expect((body['tools'] as List<Object?>).single, containsPair('name', 'read_file'));
  });

  test('Gemini maps text, function calls, usage and endpoint', () async {
    final transport = _Transport(
      'data: {"candidates":[{"content":{"parts":[{"text":"Hi"},{"functionCall":{"name":"read_file","args":{"path":"a.txt"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}\n\n',
    );
    final client = GeminiClient(
      apiKey: 'secret',
      model: 'gemini-test',
      clientFactory: () => transport,
    );

    final chunks = await client.stream(
      messages: const <LlmMessage>[LlmMessage.system('rules'), LlmMessage.user('hi')],
      tools: _tools,
    ).toList();

    expect(chunks.whereType<TextChunk>().single.text, 'Hi');
    final call = chunks.whereType<ToolCallChunk>().single;
    expect(call.name, 'read_file');
    expect(call.argumentsFragment, contains('a.txt'));
    final done = chunks.whereType<DoneChunk>().single;
    expect(done.usage.inputTokens, 5);
    expect(done.usage.outputTokens, 2);
    expect(transport.request!.url.path, contains('gemini-test:streamGenerateContent'));
  });
}
