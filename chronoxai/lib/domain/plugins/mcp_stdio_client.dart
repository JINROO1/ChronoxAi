import 'dart:io';

import 'external_plugin_rpc.dart';

/// Cliente MCP sobre stdio line-delimited, para servidores locales o npm/npx.
class McpStdioClient {
  McpStdioClient(Process process)
      : this.withTransport(
          ProcessPluginTransport(process, sendShutdown: false),
        );

  McpStdioClient.withTransport(final ExternalPluginTransport transport)
      : _rpc = ExternalPluginRpc(transport);

  final ExternalPluginRpc _rpc;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final result = await _rpc.request('initialize', <String, Object?>{
      'protocolVersion': '2025-03-26',
      'capabilities': <String, Object?>{},
      'clientInfo': <String, Object?>{
        'name': 'chronox-ai',
        'version': '0.2.0',
      },
    });
    if (result['protocolVersion'] is! String) {
      throw const FormatException('MCP server did not negotiate protocol version.');
    }
    _rpc.notify('notifications/initialized', const <String, Object?>{});
    _initialized = true;
  }

  Future<List<Map<String, Object?>>> listTools() async {
    await initialize();
    final result = await _rpc.request('tools/list', const <String, Object?>{});
    final tools = result['tools'];
    if (tools is! List) return const <Map<String, Object?>>[];
    return tools
        .whereType<Map<Object?, Object?>>()
        .map((final tool) => tool.cast<String, Object?>())
        .toList(growable: false);
  }

  Future<String> callTool(
    final String name,
    final Map<String, Object?> arguments,
  ) async {
    await initialize();
    final result = await _rpc.request('tools/call', <String, Object?>{
      'name': name,
      'arguments': arguments,
    });
    final contents = result['content'];
    final text = contents is List
        ? contents.map((final item) {
            if (item is Map) return (item['text'] ?? item['uri'] ?? '').toString();
            return item.toString();
          }).where((final value) => value.isNotEmpty).join('\n')
        : '';
    if (result['isError'] == true) {
      throw McpStdioException('MCP tool $name failed: $text');
    }
    return text;
  }

  Future<void> dispose() => _rpc.dispose();
}

class McpStdioException implements Exception {
  const McpStdioException(this.message);
  final String message;
  @override
  String toString() => message;
}
