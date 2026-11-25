import 'package:chronoxai/domain/plugins/web_research.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebResearch URL safety', () {
    test('accepts public HTTP(S) URLs on their default ports', () {
      expect(
        WebResearch.validateUrl('https://example.com/docs').host,
        'example.com',
      );
      expect(
        WebResearch.validateUrl('http://example.com:80/docs').path,
        '/docs',
      );
      expect(
        WebResearch.validateUrl('https://[2001:4860:4860::8888]/').host,
        '2001:4860:4860::8888',
      );
    });

    test('rejects non-web schemes, user info, unusual ports and local hosts',
        () {
      for (final url in <String>[
        'file:///etc/passwd',
        'ftp://example.com/file',
        'https://user:pass@example.com/',
        'https://example.com:8443/',
        'http://localhost/',
        'http://service.local/',
        'http://metadata.internal/',
      ]) {
        expect(() => WebResearch.validateUrl(url), throwsArgumentError, reason: url);
      }
    });

    test('rejects IPv4, IPv6 and legacy numeric private-address forms', () {
      for (final url in <String>[
        'http://127.0.0.1/',
        'http://10.0.0.2/',
        'http://192.168.1.10/',
        'http://169.254.169.254/latest/meta-data/',
        'http://[::1]/',
        'http://[::ffff:127.0.0.1]/',
        'http://192.0.2.5/',
        'http://2130706433/',
      ]) {
        expect(() => WebResearch.validateUrl(url), throwsArgumentError, reason: url);
      }
    });

    test('extracts title and visible text without scripts or markup', () {
      const html = '''
<html><head><title>Alpha &amp; Beta</title><script>ignore()</script></head>
<body><p>First&nbsp;claim</p><style>.x { display:none }</style>
<p>Second &lt;claim&gt;</p></body></html>
''';
      expect(WebResearch.pageTitle(html), 'Alpha & Beta');
      final text = WebResearch.stripMarkup(html);
      expect(text, contains('First claim'));
      expect(text, contains('Second <claim>'));
      expect(text, isNot(contains('ignore()')));
      expect(text, isNot(contains('display:none')));
    });

    test('limits extracted text size', () {
      final large = '<p>${'x' * (WebResearch.maxExtractedCharacters + 100)}</p>';
      final extracted = WebResearch.extractText(large);
      expect(extracted, startsWith('x' * WebResearch.maxExtractedCharacters));
      expect(extracted, endsWith('[contenido truncado]'));
      expect(extracted.length, lessThan(WebResearch.maxExtractedCharacters + 40));
    });
  });
}
