/// Parser acotado para la página HTML de resultados de DuckDuckGo.
/// No ejecuta scripts ni carga recursos remotos; solo extrae resultados visibles.
class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}

abstract final class WebSearchParser {
  static final RegExp _resultBlock = RegExp(
    r"""<div[^>]*class=["'][^"']*result[^"']*["'][^>]*>([\s\S]*?)(?=<div[^>]*class=["'][^"']*result[^"']*["']|$)""",
    caseSensitive: false,
  );
  static final RegExp _titleLink = RegExp(
    r"""<a[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>""",
    caseSensitive: false,
  );
  static final RegExp _snippet = RegExp(
    r"""<(?:a|div)[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>([\s\S]*?)</(?:a|div)>""",
    caseSensitive: false,
  );

  static List<WebSearchResult> parse(final String html, {int limit = 5}) {
    final results = <WebSearchResult>[];
    for (final block in _resultBlock.allMatches(html)) {
      final content = block.group(1) ?? '';
      final link = _titleLink.firstMatch(content);
      if (link == null) continue;
      final title = _text(link.group(2) ?? '');
      final url = _destination(link.group(1) ?? '');
      final snippet = _snippet.firstMatch(content)?.group(1) ?? '';
      if (title.isEmpty || url.isEmpty) continue;
      results.add(WebSearchResult(
        title: title,
        url: url,
        snippet: _text(snippet),
      ));
      if (results.length >= limit) break;
    }
    return List<WebSearchResult>.unmodifiable(results);
  }

  static String _destination(final String raw) {
    final uri = Uri.tryParse(_decode(raw));
    if (uri == null) return '';
    final redirected = uri.queryParameters['uddg'];
    if (redirected != null) return redirected;
    if (uri.scheme == 'https' || uri.scheme == 'http') return uri.toString();
    return '';
  }

  static String _text(final String html) {
    final decoded = _decode(html);
    final withoutMarkup = decoded
        .replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _decode(withoutMarkup);
  }

  static String _decode(String text) => text
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&nbsp;', ' ')
          .replaceAllMapped(RegExp(r'&#(\d+);'), (final match) {
        final code = int.tryParse(match.group(1) ?? '');
        return code == null ? match.group(0)! : String.fromCharCode(code);
      });
}
