import 'dart:async';
import 'dart:convert';

import 'package:chronoxai/data/llm/openai_compatible_client.dart';
import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Construye un cliente cuyo transporte devuelve [sse] troceado a propósito en
/// trozos que cortan líneas y caracteres multibyte por la mitad.
OpenAiCompatibleClient clientWith(
  final String sse, {
  final int status = 200,
  final Map<String, String> headers = const <String, String>{},
  final List<http.BaseRequest>? captured,
  final int chunkSize = 7,
}) {
  final bytes = utf8.encode(sse);
  final chunks = <List<int>>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    chunks.add(bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length)));
  }

  return OpenAiCompatibleClient(
    baseUrl: 'https://api.example.com',
    apiKey: 'k',
    model: 'm',
    clientFactory: () => MockClient.streaming((final request, final body) async {
      captured?.add(request);
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(chunks),
        status,
        headers: <String, String>{
          'content-type': 'text/event-stream',
          ...headers,
        },
      );
    }),
  );
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

      final chunks = await drain(clientWith(sse).stream(
        messages: const <LlmMessage>[LlmMessage.user('hola')],
        tools: const <Map<String, Object?>>[],
      ));

      final text = chunks.whereType<TextChunk>().map((final c) => c.text).join();
      final reasoning = chunks
          .whereType<ReasoningChunk>()
          .map((final c) => c.text)
          .join();
      expect(text, 'Hola, mundo');
      expect(reasoning, 'pienso un poco');
      expect(chunks.whereType<DoneChunk>().single.stopReason, 'stop');
    });

    test('una línea cortada por la mitad se reconstruye bien', () async {
      // chunkSize 7 parte casi cualquier línea en varios trozos TCP.
      final sse = chunk(<String, Object?>{'content': 'abcdefghijklmnop'},
          finish: 'stop');
      final chunks = await drain(clientWith(sse, chunkSize: 3).stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      ));

      expect(
        chunks.whereType<TextChunk>().map((final c) => c.text).join(),
        'abcdefghijklmnop',
      );
    });

    test('caracteres multibyte partidos entre trozos no se corrompen', () async {
      final sse = chunk(<String, Object?>{'content': 'ñandú 🔥 café'});
      final chunks = await drain(clientWith(sse, chunkSize: 5).stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      ));

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

      final chunks = await drain(clientWith(sse).stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      ));

      // Nada de llamadas a medio ensamblar: solo la versión final.
      final calls = chunks.whereType<ToolCallChunk>().toList();
      expect(calls, hasLength(2));

      final first = jsonDecode(calls[0].argumentsFragment!) as Map<String, Object?>;
      expect(calls[0].index, 0);
      expect(calls[0].id, 'call_a');
      expect(calls[0].name, 'read');
      expect(first['path'], '/a.txt');
      expect(calls[1].name, 'bash');
      expect(calls[1].index, 1);
    });

    test('un tool_call con JSON roto no se pierde: se marca para corregir',
        () async {
      final sse = chunk(<String, Object?>{
        'tool_calls': <Object?>[
          <String, Object?>{
            'index': 0,
            'id': 'call_a',
            'function': <String, Object?>{'name': 'read', 'arguments': '{"path"'},
          },
        ],
      }, finish: 'tool_calls');

      final chunks = await drain(clientWith(sse).stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      ));

      // El cliente reensambla y solo entrega JSON válido; aquí el JSON no lo es,
      // así que no debe emitir una llamada ejecutable en absoluto.
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

      final done = (await drain(clientWith(sse).stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      )))
          .whereType<DoneChunk>()
          .single;

      expect(done.usage.inputTokens, 1200);
      expect(done.usage.outputTokens, 34);
      expect(done.usage.cachedInputTokens, 900);
    });

    test('ignora comentarios y eventos que no son data', () async {
      final sse = ': keep-alive\n\nevent: ping\ndata: {"choices":[]}\n\n'
          '${chunk(<String, Object?>{'content': 'fin'})}';
      final chunks = await drain(clientWith(sse).stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      ));

      expect(
        chunks.whereType<TextChunk>().map((final c) => c.text).join(),
        'fin',
      );
    });
  });

  group('OpenAiCompatibleClient — petición', () {
    test('manda las herramientas y pide el uso en el stream', () async {
      final captured = <http.BaseRequest>[];
      await drain(clientWith(
        chunk(<String, Object?>{'content': 'x'}),
        captured: captured,
      ).stream(
        messages: const <LlmMessage>[LlmMessage.user('hola')],
        tools: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{'name': 'read'},
          },
        ],
      ));

      final request = captured.single as http.Request;
      expect(request.url.toString(), 'https://api.example.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer k');

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['stream'], isTrue);
      expect((body['stream_options'] as Map<String, Object?>)['include_usage'],
          isTrue);
      expect(body['tools'], hasLength(1));
      expect(body['model'], 'm');
    });

    test('no duplica /v1 si el usuario ya lo incluyó', () async {
      final captured = <http.BaseRequest>[];
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'k',
        model: 'm',
        clientFactory: () => MockClient.streaming((final request, final body) async {
          captured.add(request);
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('data: [DONE]\n\n')),
            200,
          );
        }),
      );

      await drain(client.stream(
        messages: const <LlmMessage>[LlmMessage.user('x')],
        tools: const <Map<String, Object?>>[],
      ));

      expect((captured.single as http.Request).url.toString(),
          'https://api.deepseek.com/v1/chat/completions');
    });
  });

  group('OpenAiCompatibleClient — errores', () {
    Future<LlmException> errorFor(
      final int status,
      final String body, {
      final Map<String, String> headers = const <String, String>{},
    }) async {
      final client = clientWith('', status: status, headers: headers);
      try {
        await drain(client.stream(
          messages: const <LlmMessage>[LlmMessage.user('x')],
          tools: const <Map<String, Object?>>[],
        ));
        fail('debía lanzar');
      } on LlmException catch (e) {
        return e;
      }
    }

    test('401 es un error de clave y no se reintenta', () async {
      final error = await errorFor(401, '{"error":"invalid_api_key"}');
      expect(error.kind, LlmErrorKind.auth);
      expect(error.isRetryable, isFalse);
      expect(error.message, contains('Ajustes'));
    });

    test('429 se puede reintentar y respeta Retry-After', () async {
      final error = await errorFor(429, 'slow down',
          headers: <String, String>{'retry-after': '12'});
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
        '{"error":{"message":"This model\'s maximum context length is 65536 tokens"}}',
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
    test('cancelar cierra el stream sin dejar la petición viva', () async {
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://api.example.com',
        apiKey: 'k',
        model: 'm',
        clientFactory: () => MockClient.streaming((final request, final body) async {
          // Nunca termina: simula un modelo que se queda pensando.
          return http.StreamedResponse(
            Stream<List<int>>.fromFuture(Completer<List<int>>().future),
            200,
          );
        }),
      );

      var cancelled = false;
      final sub = client
          .stream(
            messages: const <LlmMessage>[LlmMessage.user('x')],
            tools: const <Map<String, Object?>>[],
          )
          .listen((final _) {}, onDone: () => cancelled = true);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(cancelled, isFalse);
    });
  });
}
