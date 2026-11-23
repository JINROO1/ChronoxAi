import 'package:http/http.dart' as http;

import '../../domain/plugins/seams.dart';

/// Implementación HTTP del seam de red para plugins web y MCP.
class HttpNetworkSeam implements NetworkSeam {
  HttpNetworkSeam({http.Client Function()? clientFactory})
      : _newClient = clientFactory ?? http.Client.new;

  final http.Client Function() _newClient;

  @override
  Future<NetworkResponse> get(
    final Uri uri, {
    final Map<String, String>? headers,
  }) =>
      _send('GET', uri, headers: headers);

  @override
  Future<NetworkResponse> post(
    final Uri uri, {
    final Map<String, String>? headers,
    final String? body,
  }) =>
      _send('POST', uri, headers: headers, body: body);

  Future<NetworkResponse> _send(
    final String method,
    final Uri uri, {
    final Map<String, String>? headers,
    final String? body,
  }) async {
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw ArgumentError.value(uri, 'uri', 'Solo se permiten HTTP(S).');
    }
    final client = _newClient();
    try {
      final request = http.Request(method, uri)
        ..headers.addAll(headers ?? const <String, String>{})
        ..body = body ?? '';
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      return NetworkResponse(
        statusCode: response.statusCode,
        body: await response.stream.bytesToString(),
        headers: response.headers,
      );
    } finally {
      client.close();
    }
  }
}
