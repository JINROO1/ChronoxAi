import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  Future<NetworkResponse> getWeb(
    final Uri uri, {
    final Map<String, String>? headers,
    final int maxResponseBytes = 1000000,
  }) async {
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(maxResponseBytes, 'maxResponseBytes');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw ArgumentError.value(uri, 'uri', 'Solo se permiten HTTP(S).');
    }
    final client = _newClient();
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(headers ?? const <String, String>{});
      final response =
          await client.send(request).timeout(const Duration(seconds: 15));
      final declaredLength = int.tryParse(response.headers['content-length'] ?? '');
      if (declaredLength != null && declaredLength > maxResponseBytes) {
        await response.stream.listen((final _) {}).cancel();
        throw const FormatException('Web response exceeds the allowed size.');
      }
      final bytes = BytesBuilder(copy: false);
      final completer = Completer<NetworkResponse>();
      var received = 0;
      timer = Timer(const Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException('Web response timed out.'));
        }
      });
      subscription = response.stream.listen(
        (final chunk) {
          received += chunk.length;
          if (received > maxResponseBytes) {
            if (!completer.isCompleted) {
              completer.completeError(
                const FormatException('Web response exceeds the allowed size.'),
              );
            }
            subscription?.cancel();
          } else {
            bytes.add(chunk);
          }
        },
        onError: (final Object error, final StackTrace stackTrace) {
          if (!completer.isCompleted) completer.completeError(error, stackTrace);
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(NetworkResponse(
              statusCode: response.statusCode,
              body: utf8.decode(bytes.takeBytes(), allowMalformed: true),
              headers: response.headers,
            ));
          }
        },
        cancelOnError: true,
      );
      return await completer.future;
    } finally {
      timer?.cancel();
      await subscription?.cancel();
      client.close();
    }
  }

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
