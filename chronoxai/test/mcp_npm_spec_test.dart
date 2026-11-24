import 'package:chronoxai/domain/plugins/mcp_npm_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses scoped, exactly pinned package and binary', () {
    final package = PinnedMcpPackage.parse(<String>[
      'npm-package',
      '@modelcontextprotocol/server-filesystem@1.2.3',
      'mcp-server-filesystem',
    ]);
    expect(package.spec, '@modelcontextprotocol/server-filesystem@1.2.3');
    expect(package.binary, 'mcp-server-filesystem');
  });

  test('rejects floating versions and unsafe bin names', () {
    expect(
      () => PinnedMcpPackage.parse(
          <String>['npm-package', 'example@latest', 'server']),
      throwsFormatException,
    );
    expect(
      () => PinnedMcpPackage.parse(
          <String>['npm-package', 'example@1.0.0', '../server']),
      throwsFormatException,
    );
  });
}
