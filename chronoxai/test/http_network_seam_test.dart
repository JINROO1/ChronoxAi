import 'dart:convert';

import 'package:chronoxai/data/network/http_network_seam.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('HttpNetworkSeam.getWeb', () {
    test('does not automatically follow redirects and preserves status metadata',
        () async {
      var followRedirects = true;
      final seam = HttpNetworkSeam(
        clientFactory: () => MockClient((final request) async {
          followRedirects = request.followRedirects;
          return http.Response('', 302, headers: <String, String>{
            'location': 'http://127.0.0.1/private',
          });
        }),
      );

      final response = await seam.getWeb(Uri.parse('https://example.com'));

      expect(followRedirects, isFalse);
      expect(response.statusCode, 302);
      expect(response.headers['location'], 'http://127.0.0.1/private');
    });

    test('bounds response bytes before returning content', () async {
      final seam = HttpNetworkSeam(
        clientFactory: () => MockClient((final _) async =>
            http.Response('x' * 50, 200)),
      );

      await expectLater(
        seam.getWeb(
          Uri.parse('https://example.com'),
          maxResponseBytes: 10,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodes UTF-8 response text correctly', () async {
      final seam = HttpNetworkSeam(
        clientFactory: () => MockClient((final _) async => http.Response.bytes(
              utf8.encode('Información pública'),
              200,
              headers: const <String, String>{
                'content-type': 'text/plain; charset=utf-8',
              },
            )),
      );

      final response = await seam.getWeb(Uri.parse('https://example.com'));

      expect(response.body, 'Información pública');
    });
  });
}
