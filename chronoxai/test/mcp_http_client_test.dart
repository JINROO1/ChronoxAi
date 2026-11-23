import 'dart:convert';

import 'package:chronoxai/domain/plugins/mcp_http_client.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNetwork implements NetworkSeam {
  _FakeNetwork(this.responses);
  final List<NetworkResponse> responses;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<Map<String, String>?> headers = <Map<String, String>?>[];

  @override
  Future<NetworkResponse> post(Uri uri,
      {Map<String, String>? headers, String? body}) async {
    this.headers.add(headers);
    requests.add(jsonDecode(body!) as Map<String, Object?>);
    return responses.removeAt(0);
  }

  @override
  Future<NetworkResponse> get(Uri uri, {Map<String, String>? headers}) async =>
      throw UnimplementedError();
}

void main() {
  test('initializa, negocia sesión y llama herramientas MCP', () async {
    final network = _FakeNetwork(<NetworkResponse>[
      const NetworkResponse(
        statusCode: 200,
        body:
            '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}',
        headers: <String, String>{'Mcp-Session-Id': 'sid-1'},
      ),
      const NetworkResponse(statusCode: 202, body: ''),
      const NetworkResponse(
        statusCode: 200,
        body:
            '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}',
      ),
      const NetworkResponse(
        statusCode: 200,
        body:
            '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"pong"}]}}',
      ),
    ]);
    final client = McpHttpClient(
      network: network,
      endpoint: Uri.parse('https://mcp.example.com/mcp'),
    );

    final tools = await client.listTools();
    final result =
        await client.callTool('echo', <String, Object?>{'text': 'ping'});

    expect(tools.single['name'], 'echo');
    expect(result, 'pong');
    expect(network.requests.map((final request) => request['method']), <String>[
      'initialize',
      'notifications/initialized',
      'tools/list',
      'tools/call'
    ]);
    expect(network.headers[2]?['Mcp-Session-Id'], 'sid-1');
    expect(network.requests.last['params'], <String, Object?>{
      'name': 'echo',
      'arguments': <String, Object?>{'text': 'ping'},
    });
  });

  test('acepta respuesta JSON-RPC encapsulada en SSE', () async {
    final network = _FakeNetwork(<NetworkResponse>[
      const NetworkResponse(
        statusCode: 200,
        body:
            'data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}\n\n',
      ),
      const NetworkResponse(statusCode: 202, body: ''),
      const NetworkResponse(
        statusCode: 200,
        body: '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}',
      ),
    ]);
    final client = McpHttpClient(
      network: network,
      endpoint: Uri.parse('https://mcp.example.com/mcp'),
    );

    expect(await client.listTools(), isEmpty);
  });
}
