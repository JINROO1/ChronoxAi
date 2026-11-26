import 'dart:async';
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
  Completer<void>? generationGate;
  Completer<void>? generationSettled;
  Completer<void>? loadGate;
  Completer<void>? loadSettled;
  int generateCalls = 0;
  Object? generationError;

  @override
  String get model => 'Qwen3.5-0.8B-Q4_K_M';

  @override
  int? get contextWindow => 4096;

  @override
  bool get isLoaded => loaded;

  @override
  Future<void> load(File modelFile) async {
    try {
      await loadGate?.future;
      loaded = true;
    } finally {
      if (loadSettled != null && !loadSettled!.isCompleted) {
        loadSettled!.complete();
      }
    }
  }

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
    generateCalls++;
    if (generationError != null) throw generationError!;
    try {
      await generationGate?.future;
      yield response.substring(0, response.length ~/ 2);
      yield response.substring(response.length ~/ 2);
    } finally {
      if (generationSettled != null && !generationSettled!.isCompleted) {
        generationSettled!.complete();
      }
    }
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

  test('never promotes marker text after ordinary assistant prose into a tool',
      () async {
    final engine = _FakeEngine()
      ..response =
          'Explicación: <chronox-tool-call>{"name":"read_file","arguments":{}}</chronox-tool-call>';
    final provider = LocalLlmProvider(engine);
    const tools = <Map<String, Object?>>[
      <String, Object?>{
        'function': <String, Object?>{'name': 'read_file'},
      },
    ];

    final chunks = await provider.stream(
      messages: const <LlmMessage>[LlmMessage.user('Lee archivo')],
      tools: tools,
    ).toList();

    expect(chunks.whereType<ToolCallChunk>(), isEmpty);
    expect(
        chunks.whereType<TextChunk>().map((final chunk) => chunk.text).join(),
        engine.response);
  });

  test('normalizes earlier tool calls and results into local model history',
      () async {
    final engine = _FakeEngine();
    final provider = LocalLlmProvider(engine);
    const tools = <Map<String, Object?>>[
      <String, Object?>{
        'function': <String, Object?>{'name': 'read_file'},
      },
    ];
    const messages = <LlmMessage>[
      LlmMessage.user('Lee el archivo'),
      LlmMessage.assistant('', toolCalls: <LlmToolCall>[
        LlmToolCall(
          id: 'call_1',
          name: 'read_file',
          arguments: <String, Object?>{'path': 'README.md'},
        ),
      ]),
      LlmMessage.toolResult(toolCallId: 'call_1', content: 'contenido'),
    ];

    await provider.stream(messages: messages, tools: tools).toList();

    final history = engine.receivedMessages!;
    final assistantHistory = history.firstWhere(
      (final message) => message.role == MessageRole.assistant,
    );
    final toolResult = history.lastWhere(
      (final message) => message.content.contains('tool-result'),
    );
    expect(assistantHistory.content, contains('tool-call-history'));
    expect(assistantHistory.content, contains('README.md'));
    expect(assistantHistory.toolCalls, isEmpty);
    expect(toolResult.role, MessageRole.user);
    expect(toolResult.content, contains('call_1'));
    expect(toolResult.content, contains('contenido'));
  });

  test('routes unadvertised local tool requests to AgentLoop for rejection',
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

    final call = chunks.whereType<ToolCallChunk>().single;
    expect(call.name, '__chronox_invalid_local_tool_call__');
    expect(call.argumentsFragment, '{}');
    expect(chunks.whereType<TextChunk>(), isEmpty);
    expect((chunks.last as DoneChunk).stopReason, 'tool_calls');
  });

  test('routes truncated protocol attempts for bounded agent correction',
      () async {
    final engine = _FakeEngine()
      ..response = '<chronox-tool-call>{"name":"read_file","arguments":';
    final provider = LocalLlmProvider(engine);
    const tools = <Map<String, Object?>>[
      <String, Object?>{
        'function': <String, Object?>{'name': 'read_file'},
      },
    ];

    final chunks = await provider.stream(
      messages: const <LlmMessage>[LlmMessage.user('Lee archivo')],
      tools: tools,
    ).toList();

    expect(chunks.whereType<ToolCallChunk>().single.name,
        '__chronox_invalid_local_tool_call__');
    expect((chunks.last as DoneChunk).stopReason, 'tool_calls');
  });

  test('does not start generation if canceled while resolving/loading model',
      () async {
    final loadGate = Completer<void>();
    final loadSettled = Completer<void>();
    final engine = _FakeEngine()
      ..loaded = false
      ..loadGate = loadGate
      ..loadSettled = loadSettled;
    final provider = LocalLlmProvider(
      engine,
      modelFileResolver: () async => File('local-model.gguf'),
    );
    final subscription = provider.stream(
        messages: const <LlmMessage>[], tools: const []).listen((final _) {});

    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    loadGate.complete();
    await loadSettled.future;
    await Future<void>.delayed(Duration.zero);

    expect(engine.generateCalls, 0);
    expect(engine.cancelled, isTrue);
  });

  test('holds the generation lock until native cancellation actually settles',
      () async {
    final gate = Completer<void>();
    final settled = Completer<void>();
    final engine = _FakeEngine()
      ..generationGate = gate
      ..generationSettled = settled;
    final provider = LocalLlmProvider(engine);
    final subscription = provider.stream(
        messages: const <LlmMessage>[], tools: const []).listen((final _) {});

    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(engine.cancelled, isTrue);

    await expectLater(
      provider.stream(messages: const <LlmMessage>[], tools: const []).toList(),
      throwsA(isA<LlmException>()),
    );

    gate.complete();
    await settled.future;
    await Future<void>.delayed(Duration.zero);
    final next = await provider
        .stream(messages: const <LlmMessage>[], tools: const []).toList();
    expect(next.last, isA<DoneChunk>());
  });

  test('maps native context failures to a non-retryable local error', () async {
    final engine = _FakeEngine()
      ..generationError = StateError('El prompt excede el contexto local.');
    final provider = LocalLlmProvider(engine);

    await expectLater(
      provider.stream(messages: const <LlmMessage>[], tools: const []).toList(),
      throwsA(
        isA<LlmException>()
            .having((final error) => error.kind, 'kind', LlmErrorKind.contextLength)
            .having((final error) => error.message, 'message', contains('contexto')),
      ),
    );
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
    // Constructing a lazy stream without listening must not reserve the JNI context.
    provider.stream(messages: const <LlmMessage>[], tools: const []);
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
