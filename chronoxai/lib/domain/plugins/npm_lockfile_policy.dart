import 'dart:convert';

/// Restricts lockfiles accepted by the MCP installer to immutable npm registry
/// tarballs with a supported integrity digest. No git, file, HTTP, or custom
/// registry sources are silently installed.
class NpmLockfilePolicy {
  const NpmLockfilePolicy._();

  static const int maxPackages = 1000;

  static void validateJson(String source, {required String expectedPackage, required String expectedVersion}) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('package-lock.json no es un objeto JSON.');
    }
    final packages = decoded['packages'];
    if (packages is! Map<String, dynamic> || packages.length > maxPackages) {
      throw const FormatException('Lockfile inválido o con demasiados paquetes.');
    }
    final root = packages[''];
    final rootDependencies = root is Map ? root['dependencies'] : null;
    final packageEntry = packages['node_modules/$expectedPackage'];
    if (rootDependencies is! Map ||
        rootDependencies[expectedPackage] != expectedVersion ||
        packageEntry is! Map ||
        packageEntry['version'] != expectedVersion) {
      throw const FormatException('El lockfile no fija el paquete MCP configurado.');
    }

    for (final entry in packages.entries) {
      if (entry.key == '') continue;
      final package = entry.value;
      if (package is! Map) {
        throw FormatException('Entrada de lockfile inválida: ${entry.key}');
      }
      if (package['link'] == true) {
        throw FormatException('No se admiten enlaces locales en lockfile: ${entry.key}');
      }
      final resolved = package['resolved'];
      if (resolved is! String) {
        throw FormatException('Falta origen tarball en lockfile: ${entry.key}');
      }
      final uri = Uri.tryParse(resolved);
      if (uri == null || uri.scheme != 'https' || uri.host != 'registry.npmjs.org') {
        throw FormatException('Origen no permitido en lockfile: ${entry.key}');
      }
      final integrity = package['integrity'];
      if (integrity is! String ||
          !RegExp(r'^sha(?:512|384|256)-[A-Za-z0-9+/]+={0,2}(?:\s+sha(?:512|384|256)-[A-Za-z0-9+/]+={0,2})*$')
              .hasMatch(integrity)) {
        throw FormatException('Falta integridad criptográfica en lockfile: ${entry.key}');
      }
    }
  }
}
