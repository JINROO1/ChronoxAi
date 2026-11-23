import 'dart:async';
import 'dart:convert';

import 'package:chronoxai/data/llm/openai_compatible_client.dart';
import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Transporte falso: devuelve los bytes indicados y recuerda la petición.
///
/// Se implementa aquí en lugar de usar `MockClient` para no depender de una API
/// de terceros que cambia entre versiones; lo único que se necesita es
/// `BaseClient.send`.
class FakeTransport extends http.BaseClient {
  FakeTransport(
    this.chunks, {
    this.statusCode = 200,
    this.headers = const <String, String>{},
  });

  final List<List<int>> chunks;
  final int statusCode;
  final Map<String, String> headers;

  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(final http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks),
      statusCode,
      headers: headers,
      request: request,
    );
  }

  @override
  void close() => closed = true;
}

/// Parte [sse] en trozos de [chunkSize] bytes, cortando por donde haga falta.
List<List<int>> sliced(final String sse, {final int chunkSize = 7}) {
  final bytes = utf8.encode(sse);
  final out = <List<int>>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    out.add(bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length)));
  }
  return out;
}

OpenAiCompatibleClient clientWith(
  final String sse, {
  final int status = 200,
  final Map<String, String> headers = const <String, String>{},
  final FakeTransport? transport,
  final int chunkSize = 7,
}) {
  final fake = transport ?? FakeTransport(<List<int>>[]);
  if (transport == null) {
    fake.chunks.addAll(sliced(sse, chunkSize: chunkSize));
  }
  return OpenAiCompatibleClient(
    baseUrl: 'https://api.example.com',
    apiKey: 'k',
    model: 'm',
    clientFactory: () => _TransportProxy(fake),
  );
}

/// Envuelve el transporte falso para no compartir el estado de `closed` entre
/// las peticiones que hace el cliente.
class _TransportProxy extends http.BaseClient {
  _TransportProxy(this.inner);
  final FakeTransport inner;

  @override
  Future<http.StreamedResponse> send(final http.BaseRequest request) =>
      inner.send(request);
}

String chunk(final Map<String, Object?> delta, {final String? finish}) =>
    'data: ${jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{'delta': delta, 'finish_reason': finish},
      ],
    })}\n\n';

Future<List<LlmChunk>> drain(final Stream<LlmChunk> stream) => stream.toList();

void main() {
  group('OpenAiCompatibleClient — streaming', () {
    test('ensambla texto y razonamiento de varios eventos', () async {
      final sse = <String>[
        chunk(<String, Object?>{'role': 'assistant'}),
        chunk(<String, Object?>{'reasoning_content': 'pienso '}),
        chunk(<String, Object?>{'reasoning_content': 'un poco'}),
        chunk(<String, Object?>{'content': 'Hola'}),
        chunk(<String, Object?>{'content': ', mundo'}, finish: 'stop'),
        'data: [DONE]\n\n',
      ].join();

      final chunks = await drain(
        clientWith(sse).stream(
          messages: const <LlmMessage>[LlmMessage.user('hola')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      final text =
          chunks.whereType<TextChunk>().map((final c) => c.text).join();
      final reasoning =
          chunks.whereType<ReasoningChunk>().map((final c) => c.text).join();
      expect(text, 'Hola, mundo');
      expect(reasoning, 'pienso un poco');
      expect(chunks.whereType<DoneChunk>().single.stopReason, 'stop');
    });

    test('una línea partida entre trozos se reconstruye bien', () async {
      final sse = chunk(
        <String, Object?>{'content': 'abcdefghijklmnop'},
        finish: 'stop',
      );
      final chunks = await drain(
        clientWith(sse, chunkSize: 3).stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      expect(
        chunks.whereType<TextChunk>().map((final c) => c.text).join(),
        'abcdefghijklmnop',
      );
    });

    test('caracteres multibyte partidos no se corrompen', () async {
      final sse = chunk(<String, Object?>{'content': 'ñandú 🔥 café'});
      final chunks = await drain(
        clientWith(sse, chunkSize: 5).stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      expect(
        chunks.whereType<TextChunk>().map((final c) => c.text).join(),
        'ñandú 🔥 café',
      );
    });

    test('ensambla tool_calls fragmentadas por índice', () async {
      final sse = <String>[
        chunk(<String, Object?>{
          'tool_calls': <Object?>[
            <String, Object?>{
              'index': 0,
              'id': 'call_a',
              'function': <String, Object?>{'name': 'read', 'arguments': '{"pa'},
            },
          ],
        }),
        chunk(<String, Object?>{
          'tool_calls': <Object?>[
            <String, Object?>{
              'index': 0,
              'function': <String, Object?>{'arguments': 'th":"/a.txt"}'},
            },
          ],
        }),
        chunk(<String, Object?>{
          'tool_calls': <Object?>[
            <String, Object?>{
              'index': 1,
              'id': 'call_b',
              'function': <String, Object?>{'name': 'bash', 'arguments': '{}'},
            },
          ],
        }, finish: 'tool_calls'),
      ].join();

      final chunks = await drain(
        clientWith(sse).stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      // Nada de llamadas a medio ensamblar: solo la versión final.
      final calls = chunks.whereType<ToolCallChunk>().toList();
      expect(calls, hasLength(2));

      final first =
          jsonDecode(calls[0].argumentsFragment!) as Map<String, Object?>;
      expect(calls[0].index, 0);
      expect(calls[0].id, 'call_a');
      expect(calls[0].name, 'read');
      expect(first['path'], '/a.txt');
      expect(calls[1].name, 'bash');
      expect(calls[1].index, 1);
    });

    test('un tool_call con JSON roto no se entrega como ejecutable', () async {
      final sse = chunk(
        <String, Object?>{
          'tool_calls': <Object?>[
            <String, Object?>{
              'index': 0,
              'id': 'call_a',
              'function': <String, Object?>{'name': 'read', 'arguments': '{"path"'},
            },
          ],
        },
        finish: 'tool_calls',
      );

      final chunks = await drain(
        clientWith(sse).stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      expect(chunks.whereType<ToolCallChunk>(), isEmpty);
      expect(chunks.whereType<DoneChunk>(), hasLength(1));
    });

    test('lee el uso de tokens, incluidos los cacheados', () async {
      final sse = <String>[
        chunk(<String, Object?>{'content': 'ok'}, finish: 'stop'),
        'data: ${jsonEncode(<String, Object?>{
          'choices': <Object?>[],
          'usage': <String, Object?>{
            'prompt_tokens': 1200,
            'completion_tokens': 34,
            'prompt_tokens_details': <String, Object?>{'cached_tokens': 900},
          },
        })}\n\n',
      ].join();

      final done = (await drain(
        clientWith(sse).stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      ))
          .whereType<DoneChunk>()
          .single;

      expect(done.usage.inputTokens, 1200);
      expect(done.usage.outputTokens, 34);
      expect(done.usage.cachedInputTokens, 900);
    });

    test('ignora comentarios y eventos que no son data', () async {
      final sse =
          ': keep-alive\n\nevent: ping\ndata: {"choices":[]}\n\n'
          '${chunk(<String, Object?>{'content': 'fin'})}';
      final chunks = await drain(
        clientWith(sse).stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      expect(
        chunks.whereType<TextChunk>().map((final c) => c.text).join(),
        'fin',
      );
    });
  });

  group('OpenAiCompatibleClient — petición', () {
    test('manda las herramientas y pide el uso en el stream', () async {
      final transport = FakeTransport(
        sliced(chunk(<String, Object?>{'content': 'x'})),
      );
      await drain(
        clientWith('', transport: transport).stream(
          messages: const <LlmMessage>[LlmMessage.user('hola')],
          tools: <Map<String, Object?>>[
            <String, Object?>{
              'type': 'function',
              'function': <String, Object?>{'name': 'read'},
            },
          ],
        ),
      );

      final request = transport.requests.single as http.Request;
      expect(
        request.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(request.headers['Authorization'], 'Bearer k');

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['stream'], isTrue);
      final options = body['stream_options'] as Map<String, Object?>;
      expect(options['include_usage'], isTrue);
      expect(body['tools'], hasLength(1));
      expect(body['model'], 'm');
    });

    test('no duplica /v1 si el usuario ya lo incluyó', () async {
      final transport = FakeTransport(sliced('data: [DONE]\n\n'));
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'k',
        model: 'm',
        clientFactory: () => _TransportProxy(transport),
      );

      await drain(
        client.stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ),
      );

      expect(
        (transport.requests.single as http.Request).url.toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
    });
  });

  group('OpenAiCompatibleClient — errores', () {
    Future<LlmException> errorFor(
      final int status,
      final String body, {
      final Map<String, String> headers = const <String, String>{},
    }) async {
      final transport = FakeTransport(
        utf8.encode(body).map((final b) => <int>[b]).toList(),
        statusCode: status,
        headers: headers,
      );
      try {
        await drain(
          clientWith('', transport: transport).stream(
            messages: const <LlmMessage>[LlmMessage.user('x')],
            tools: const <Map<String, Object?>>[],
          ),
        );
      } on LlmException catch (e) {
        return e;
      }
      throw StateError('La petición no lanzó LlmException');
    }

    test('401 es un error de clave y no se reintenta', () async {
      final error = await errorFor(401, '{"error":"invalid_api_key"}');
      expect(error.kind, LlmErrorKind.auth);
      expect(error.isRetryable, isFalse);
      expect(error.message, contains('Ajustes'));
    });

    test('429 se puede reintentar y respeta Retry-After', () async {
      final error = await errorFor(
        429,
        'slow down',
        headers: <String, String>{'retry-after': '12'},
      );
      expect(error.kind, LlmErrorKind.rateLimit);
      expect(error.isRetryable, isTrue);
      expect(error.retryAfter, const Duration(seconds: 12));
    });

    test('503 es error de servidor y se reintenta', () async {
      final error = await errorFor(503, 'unavailable');
      expect(error.kind, LlmErrorKind.server);
      expect(error.isRetryable, isTrue);
    });

    test('400 por contexto excedido se clasifica como compactable', () async {
      final error = await errorFor(
        400,
        '{"error":{"message":"maximum context length is 65536 tokens"}}',
      );
      expect(error.kind, LlmErrorKind.contextLength);
      expect(error.isRetryable, isFalse);
    });

    test('400 por otra causa no se confunde con el contexto', () async {
      final error = await errorFor(400, '{"error":"bad request"}');
      expect(error.kind, LlmErrorKind.unknown);
    });
  });

  group('OpenAiCompatibleClient — cancelación', () {
    test('cancelar deja de consumir el stream', () async {
      // Stream infinito: simula un modelo que se queda pensando.
      final transport = FakeTransport(<List<int>>[]);
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://api.example.com',
        apiKey: 'k',
        model: 'm',
        clientFactory: () => _EndlessClient(transport),
      );

      var done = false;
      final sub = client
          .stream(
            messages: const <LlmMessage>[LlmMessage.user('x')],
            tools: const <Map<String, Object?>>[],
          )
          .listen((final _) {}, onDone: () => done = true);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(done, isFalse);
    });
  });
}

/// Cliente cuya respuesta nunca termina.
class _EndlessClient extends http.BaseClient {
  _EndlessClient(this.inner);
  final FakeTransport inner;

  @override
  Future<http.StreamedResponse> send(final http.BaseRequest request) async {
    inner.requests.add(request);
    final controller = StreamController<List<int>>();
    return http.StreamedResponse(controller.stream, 200, request: request);
  }
}
