/// A package/binary pair for isolated npm-based MCP servers.
class PinnedMcpPackage {
  const PinnedMcpPackage(
      {required this.package, required this.version, required this.binary});

  final String package;
  final String version;
  final String binary;

  String get spec => '$package@$version';

  /// Syntax: `npm-package <package>@<exact-version> <bin>`.
  static PinnedMcpPackage parse(List<String> command) {
    if (command.length != 3 || command.first != 'npm-package') {
      throw const FormatException(
        'Usa stdio:npm-package paquete@version binario.',
      );
    }
    final raw = command[1];
    final separator = raw.lastIndexOf('@');
    if (separator <= 0 || separator == raw.length - 1) {
      throw const FormatException('Fija una versión exacta: paquete@1.2.3.');
    }
    final package = raw.substring(0, separator);
    final version = raw.substring(separator + 1);
    final validPackage = RegExp(r'^(?:@[a-z0-9._-]+/)?[a-z0-9._-]+$');
    final exactVersion =
        RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$');
    if (!validPackage.hasMatch(package) || !exactVersion.hasMatch(version)) {
      throw const FormatException(
        'Nombre inválido o versión no exacta; no se permiten tags como latest.',
      );
    }
    final binary = command[2];
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(binary) ||
        binary == '.' ||
        binary == '..') {
      throw const FormatException('Nombre de ejecutable npm inválido.');
    }
    return PinnedMcpPackage(package: package, version: version, binary: binary);
  }
}
