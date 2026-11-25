import 'dart:io';

import 'package:chronoxai/data/llm/local_llm_provider.dart';
import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEngine implements LocalInferenceEngine {
  bool loaded = true;
  bool cancelled = false;
  List<LlmMessage>? receivedMessages;
  List<Map<String, Object?>>? receivedTools;
  String response = 'Hola mundo';

  @override
  String get model => 'Qwen3.5-0.8B-Q4_K_M';

  @override
  int? get contextWindow => 4096;

  @override
  bool get isLoaded => loaded;

  @override
  Future<void> load(File modelFile) async => loaded = true;

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> unload() async => loaded = false;

  @override
  Stream<String> generate({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  }) async* {
    receivedMessages = messages;
    receivedTools = tools;
    yield response.substring(0, response.length ~/ 2);
    yield response.substring(response.length ~/ 2);
  }
}

void main() {
  test('streams native text as TextChunk and terminates with DoneChunk',
      () async {
    final engine = _FakeEngine();
    final provider = LocalLlmProvider(engine);
    final messages = <LlmMessage>[const LlmMessage.user('Saluda en español')];
    final chunks = await provider.stream(
        messages: messages, tools: const <Map<String, Object?>>[]).toList();

    expect(chunks.whereType<TextChunk>().map((final c) => c.text),
        <String>['Hola ', 'mundo']);
    expect(chunks.last, isA<DoneChunk>());
    expect(engine.receivedMessages, messages);
    expect(engine.receivedTools, isEmpty);
  });

  test('converts a strict local tool envelope into a ToolCallChunk', () async {
    final engine = _FakeEngine()
      ..response =
          '<chronox-tool-call>{"name":"read_file","arguments":{"path":"README.md"}}</chronox-tool-call>';
    final provider = LocalLlmProvider(engine);
    const tools = <Map<String, Object?>>[
      <String, Object?>{
        'type': 'function',
        'function': <String, Object?>{
          'name': 'read_file',
          'description': 'Lee un archivo.',
          'parameters': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'path': <String, Object?>{'type': 'string'},
            },
            'required': <String>['path'],
          },
        },
      },
    ];

    final chunks = await provider.stream(
      messages: const <LlmMessage>[LlmMessage.user('Lee README')],
      tools: tools,
    ).toList();

    final call = chunks.whereType<ToolCallChunk>().single;
    expect(call.name, 'read_file');
    expect(call.index, 0);
    expect(call.id, startsWith('local_'));
    expect(call.argumentsFragment, '{"path":"README.md"}');
    expect(chunks.last, isA<DoneChunk>());
    expect((chunks.last as DoneChunk).stopReason, 'tool_calls');
    expect(engine.receivedTools, isEmpty);
    final system = engine.receivedMessages!.first;
    expect(system.role, MessageRole.system);
    expect(system.content, contains('chronox-tool-call'));
    expect(system.content, contains('read_file'));
    expect(chunks.whereType<TextChunk>(), isEmpty);
  });

  test('does not convert malformed or unadvertised local tool requests',
      () async {
    final engine = _FakeEngine()
      ..response =
          '<chronox-tool-call>{"name":"delete_everything","arguments":{}}</chronox-tool-call>';
    final provider = LocalLlmProvider(engine);
    const tools = <Map<String, Object?>>[
      <String, Object?>{
        'function': <String, Object?>{'name': 'read_file'},
      },
    ];

    final chunks = await provider.stream(
      messages: const <LlmMessage>[LlmMessage.user('Haz algo')],
      tools: tools,
    ).toList();

    expect(chunks.whereType<ToolCallChunk>(), isEmpty);
    expect(
        chunks.whereType<TextChunk>().map((final chunk) => chunk.text).join(),
        engine.response);
    expect(chunks.last, isA<DoneChunk>());
  });

  test('does not start inference when no local model is loaded', () async {
    final engine = _FakeEngine()..loaded = false;
    final provider = LocalLlmProvider(engine);

    await expectLater(
      provider.stream(messages: const <LlmMessage>[], tools: const []).toList(),
      throwsA(isA<LlmException>()),
    );
    expect(engine.receivedMessages, isNull);
  });

  test('rejects overlapping generations rather than sharing native state',
      () async {
    final engine = _FakeEngine();
    final provider = LocalLlmProvider(engine);
    final first = provider.stream(
      messages: const <LlmMessage>[],
      tools: const <Map<String, Object?>>[],
    );
    final subscription = first.listen((final _) {});

    await expectLater(
      provider.stream(messages: const <LlmMessage>[], tools: const []).toList(),
      throwsA(isA<LlmException>()),
    );
    await subscription.cancel();
    expect(engine.cancelled, isTrue);
  });
}
