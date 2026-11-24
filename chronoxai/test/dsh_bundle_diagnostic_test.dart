import 'package:chronoxai/domain/plugins/dsh_bundle_diagnostic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports Cordis patch and UI as unsupported without claiming import', () {
    final report = DshBundleDiagnostic.inspect(
      bundleName: 'sample.dsh.bundle',
      files: <String>[
        'cordis.patch.yml',
        'package.json',
        'src/ui/page.tsx',
      ],
      metadata: <String, Object?>{'service': 'ExampleService'},
    );

    expect(report.canImportAsMcp, isFalse);
    expect(report.toJson()['classification'], 'manual_port_required');
    expect(report.unsupported, hasLength(3));
    expect(report.toPrettyJson(), contains('No se instaló ni ejecutó código'));
  });

  test('identifies a Node package without Cordis patch as an MCP candidate only', () {
    final report = DshBundleDiagnostic.inspect(
      bundleName: 'candidate',
      files: <String>['package.json', 'src/server.js'],
    );

    expect(report.canImportAsMcp, isTrue);
    expect(report.toJson()['classification'], 'mcp_candidate');
  });
}
