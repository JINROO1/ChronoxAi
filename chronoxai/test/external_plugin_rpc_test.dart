import 'dart:async';
import 'dart:convert';

import 'package:chronoxai/domain/plugins/external_plugin_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport implements ExternalPluginTransport {
  final stdout = StreamController<String>();
  final stderr = StreamController<String>();
  final sent = <Map<String, Object?>>[];
  bool closed = false;
  void Function(Map<String, Object?> request)? onSend;

  @override
  Stream<String> get stdoutLines => stdout.stream;
  @override
  Stream<String> get stderrLines => stderr.stream;

  @override
  void sendLine(String line) {
    final request = jsonDecode(line) as Map<String, Object?>;
    sent.add(request);
    onSend?.call(request);
  }

  @override
  Future<void> close() async {
    closed = true;
    await stdout.close();
    await stderr.close();
  }
}

void main() {
  test('multiplexa JSON-RPC por id y devuelve result', () async {
    final transport = _FakeTransport();
    transport.onSend = (final request) {
      final id = request['id'];
      transport.stdout.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': <String, Object?>{'method': request['method']},
      }));
    };
    final rpc = ExternalPluginRpc(transport);

    final result = await rpc.request('tools/list', const <String, Object?>{});

    expect(result['method'], 'tools/list');
    expect(transport.sent.single['jsonrpc'], '2.0');
    expect(transport.sent.single['id'], 1);
    await rpc.dispose();
    expect(transport.closed, isTrue);
  });

  test('propaga errores JSON-RPC como excepción', () async {
    final transport = _FakeTransport();
    transport.onSend = (final request) {
      transportResponse(transport, request['id']);
    };
    final rpc = ExternalPluginRpc(transport);

    await expectLater(
      rpc.request('tools/call', const <String, Object?>{}),
      throwsA(isA<ExternalPluginException>()),
    );
    await rpc.dispose();
  });
}

void transportResponse(final _FakeTransport transport, final Object? id) {
  transport.stdout.add(jsonEncode(<String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'error': <String, Object?>{'code': -1, 'message': 'test error'},
  }));
}
