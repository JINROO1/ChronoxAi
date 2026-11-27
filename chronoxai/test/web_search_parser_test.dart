import 'package:chronoxai/domain/plugins/web_search_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extrae y decodifica resultados HTML de DuckDuckGo', () {
    const html = '''
<div class="result results_links">
  <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs&amp;rut=123">Chronox &amp; agentes</a>
  <a class="result__snippet">Guía &lt;b&gt;actual&lt;/b&gt; para agentes.</a>
</div>
<div class="result results_links">
  <a class="result__a" href="https://second.example/page">Segundo resultado</a>
  <div class="result__snippet">Otro extracto</div>
</div>
''';

    final results = WebSearchParser.parse(html);

    expect(results, hasLength(2));
    expect(results.first.title, 'Chronox & agentes');
    expect(results.first.url, 'https://example.com/docs');
    expect(results.first.snippet, 'Guía actual para agentes.');
    expect(results.last.url, 'https://second.example/page');
  });

  test('HTML vacío o malformado devuelve cero resultados sin lanzar', () {
    expect(WebSearchParser.parse(''), isEmpty);
    expect(
      WebSearchParser.parse(
        '<div class="result"><a class="result__a" href="https://x.example">sin cerrar',
      ),
      isEmpty,
    );
  });

  test('respeta límite y omite enlaces internos no resolubles', () {
    const html = '''
<div class="result"><a class="result__a" href="/internal">Interno</a></div>
<div class="result"><a class="result__a" href="https://example.com">Uno</a></div>
<div class="result"><a class="result__a" href="https://example.org">Dos</a></div>
''';

    final results = WebSearchParser.parse(html, limit: 1);

    expect(results, hasLength(1));
    expect(results.single.title, 'Uno');
  });
}
