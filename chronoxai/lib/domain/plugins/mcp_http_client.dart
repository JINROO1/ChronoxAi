import 'dart:convert';

import 'seams.dart';

/// Cliente MCP Streamable HTTP acotado al subconjunto tools/list y tools/call.
class McpHttpClient {
  McpHttpClient({required this.network, required this.endpoint});

  final NetworkSeam network;
  final Uri endpoint;
  String? _sessionId;
  int _nextId = 0;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final result = await _request('initialize', <String, Object?>{
      'protocolVersion': '2025-03-26',
      'capabilities': <String, Object?>{},
      'clientInfo': <String, Object?>{
        'name': 'chronox-ai',
        'version': '0.2.0',
      },
    });
    final protocol = result['protocolVersion'];
    if (protocol is! String || protocol.isEmpty) {
      throw const FormatException(
          'El servidor MCP no devolvió protocolVersion.');
    }
    await _notify('notifications/initialized', const <String, Object?>{});
    _initialized = true;
  }

  Future<List<Map<String, Object?>>> listTools() async {
    await initialize();
    final result = await _request('tools/list', const <String, Object?>{});
    final raw = result['tools'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw.whereType<Map<String, Object?>>().toList(growable: false);
  }

  Future<String> callTool(
    final String name,
    final Map<String, Object?> arguments,
  ) async {
    await initialize();
    final result = await _request('tools/call', <String, Object?>{
      'name': name,
      'arguments': arguments,
    });
    if (result['isError'] == true) {
      return 'MCP tool $name devolvió un error: ${_content(result['content'])}';
    }
    return _content(result['content']);
  }

  Future<Map<String, Object?>> _request(
    final String method,
    final Map<String, Object?> params,
  ) async {
    final id = ++_nextId;
    final response = await network.post(
      endpoint,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      },
      body: jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    if (!response.isSuccess) {
      throw McpException('MCP HTTP ${response.statusCode}: ${response.body}');
    }
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'mcp-session-id') {
        _sessionId = entry.value;
        break;
      }
    }
    final json = _decodeResponse(response.body);
    if (json['error'] case final Map<String, Object?> error) {
      throw McpException(
        'MCP ${error['code'] ?? ''}: ${error['message'] ?? 'error desconocido'}',
      );
    }
    final result = json['result'];
    return result is Map<String, Object?> ? result : const <String, Object?>{};
  }

  Future<void> _notify(
    final String method,
    final Map<String, Object?> params,
  ) async {
    final response = await network.post(
      endpoint,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      },
      body: jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
    if (!response.isSuccess) {
      throw McpException('MCP notification HTTP ${response.statusCode}.');
    }
  }

  static Map<String, Object?> _decodeResponse(final String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const <String, Object?>{};
    if (trimmed.startsWith('{'))
      return jsonDecode(trimmed) as Map<String, Object?>;
    // Streamable HTTP puede devolver una secuencia SSE con un evento JSON-RPC.
    for (final line in const LineSplitter().convert(trimmed)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.startsWith('{')) return jsonDecode(data) as Map<String, Object?>;
    }
    throw const FormatException('Respuesta MCP JSON/SSE no reconocida.');
  }

  static String _content(final Object? raw) {
    if (raw is! List) return raw?.toString() ?? '';
    return raw
        .map((final item) {
          if (item is Map<String, Object?>) {
            return (item['text'] ?? item['uri'] ?? item['type'] ?? '')
                .toString();
          }
          return item.toString();
        })
        .where((final text) => text.isNotEmpty)
        .join('\n');
  }
}

class McpException implements Exception {
  const McpException(this.message);
  final String message;
  @override
  String toString() => message;
}
