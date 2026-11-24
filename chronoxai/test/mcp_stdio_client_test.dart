import 'dart:async';
import 'dart:convert';

import 'package:chronoxai/domain/plugins/external_plugin_rpc.dart';
import 'package:chronoxai/domain/plugins/mcp_stdio_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements ExternalPluginTransport {
  final output = StreamController<String>();
  final input = <Map<String, Object?>>[];
  @override
  Stream<String> get stdoutLines => output.stream;
  @override
  Stream<String> get stderrLines => const Stream<String>.empty();

  @override
  void sendLine(String line) {
    final request = (jsonDecode(line) as Map).cast<String, Object?>();
    input.add(request);
    final method = request['method'];
    final id = request['id'];
    if (id == null) return;
    final result = switch (method) {
      'initialize' => <String, Object?>{'protocolVersion': '2025-03-26'},
      'tools/list' => <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{
              'name': 'demo',
              'description': 'A test tool',
              'inputSchema': <String, Object?>{'type': 'object'},
            },
          ],
        },
      'tools/call' => <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'done'},
          ],
        },
      _ => <String, Object?>{},
    };
    scheduleMicrotask(() => output.add(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        })));
  }

  @override
  Future<void> close() => output.close();
}

void main() {
  test('performs MCP handshake, tool discovery and invocation over stdio',
      () async {
    final transport = _Transport();
    final client = McpStdioClient.withTransport(transport);

    final tools = await client.listTools();
    final response = await client.callTool('demo', const <String, Object?>{});

    expect(tools.single['name'], 'demo');
    expect(response, 'done');
    expect(
        transport.input.map((final row) => row['method']),
        containsAllInOrder(
          <String>[
            'initialize',
            'notifications/initialized',
            'tools/list',
            'tools/call'
          ],
        ));
    await client.dispose();
  });
}
