import 'dart:io';

/// Guardrails and text extraction shared by the web research tools.
abstract final class WebResearch {
  static const int maxUrlCharacters = 2048;
  static const int maxResponseCharacters = 1000000;
  static const int maxExtractedCharacters = 20000;

  /// Rejects schemes, credentials, unusual ports and obvious local/private hosts.
  /// Redirects are intentionally disabled by the HTTP web-fetch path.
  static Uri validateUrl(final String raw) {
    if (raw.length > maxUrlCharacters) {
      throw ArgumentError('URL exceeds $maxUrlCharacters characters.');
    }
    final uri = Uri.tryParse(raw.trim());
    final expectedPort = uri?.scheme == 'https' ? 443 : 80;
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != expectedPort)) {
      throw ArgumentError(
          'Only public HTTP(S) URLs on their standard port are allowed.');
    }
    final host = uri.host
        .toLowerCase()
        .replaceAll(RegExp(r'^\[|\]$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    if ((!host.contains('.') && !host.contains(':')) ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.lan') ||
        host.endsWith('.internal') ||
        host.endsWith('.home.arpa') ||
        host.endsWith('.test') ||
        host.endsWith('.invalid')) {
      throw ArgumentError('Local and reserved hostnames are not allowed.');
    }
    final address = InternetAddress.tryParse(host);
    if (address != null && _isNonPublicAddress(address)) {
      throw ArgumentError(
          'Private, loopback, link-local and reserved IPs are blocked.');
    }
    // Reject legacy numeric IPv4 forms that some resolvers interpret as
    // loopback/private addresses although they are not canonical IP literals.
    if (RegExp(r'^[0-9.]+$').hasMatch(host) && address == null) {
      throw ArgumentError('Non-canonical numeric IP hosts are not allowed.');
    }
    return uri;
  }

  static bool _isNonPublicAddress(final InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      return _isNonPublicIpv4(address.rawAddress);
    }
    final bytes = address.rawAddress;
    final isIpv4Mapped = bytes.length == 16 &&
        bytes.take(10).every((final byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isIpv4Mapped && _isNonPublicIpv4(bytes.sublist(12))) return true;
    final isUnspecified = bytes.every((final byte) => byte == 0);
    return isUnspecified ||
        address.isLoopback ||
        address.isLinkLocal ||
        address.isMulticast ||
        (address.type == InternetAddressType.IPv6 &&
            bytes.isNotEmpty &&
            (bytes.first & 0xfe) == 0xfc);
  }

  static bool _isNonPublicIpv4(final List<int> parts) {
    final a = parts[0];
    final b = parts[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 192 && b == 0 && parts[2] == 0) ||
        (a == 192 && b == 0 && parts[2] == 2) ||
        (a == 192 && b == 88 && parts[2] == 99) ||
        (a == 198 && (b == 18 || b == 19 || b == 51 && parts[2] == 100)) ||
        (a == 203 && b == 0 && parts[2] == 113) ||
        (a >= 224);
  }

  static String pageTitle(final String html) {
    final match = RegExp(
      r'<title\b[^>]*>([\s\S]*?)</title\s*>',
      caseSensitive: false,
    ).firstMatch(html);
    return match == null ? '' : _decode(stripMarkup(match.group(1)!));
  }

  static String extractText(final String html) {
    final text = stripMarkup(html);
    return text.length > maxExtractedCharacters
        ? '${text.substring(0, maxExtractedCharacters)}\n[contenido truncado]'
        : text;
  }

  static String stripMarkup(final String html) {
    final text = html
        .replaceAll(
            RegExp(r'<script\b[\s\S]*?</script\s*>', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'<style\b[\s\S]*?</style\s*>', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'<noscript\b[\s\S]*?</noscript\s*>', caseSensitive: false),
            ' ')
        .replaceAll(RegExp(r'<[^>]*>'), ' ');
    return _decode(text)
        .replaceAll(RegExp(r'[\t\r ]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static String _decode(final String text) => text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}
