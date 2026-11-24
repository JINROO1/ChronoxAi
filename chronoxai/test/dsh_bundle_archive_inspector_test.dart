import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:chronoxai/domain/plugins/dsh_bundle_archive_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> makeZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return ZipEncoder().encode(archive)!;
}

void main() {
  test('inspects a DSH bundle archive without extracting or executing it', () {
    final zip = makeZip(<String, String>{
      'package.json': jsonEncode(<String, Object?>{
        'name': '@sample/mcp-server',
        'version': '1.2.3',
        'bin': <String, String>{'mcp-sample': 'dist/index.js'},
        'dependencies': <String, String>{'@modelcontextprotocol/sdk': '^1'},
      }),
      'cordis.patch.yml': 'plugins:\n  - src/index.ts',
      'src/ui/panel.tsx': 'export default {}',
    });

    final result = DshBundleArchiveInspector.inspectBytes(
      zip,
      bundleName: 'sample.dsh.bundle',
    );

    expect(result.canImportAsMcp, isFalse);
    expect(result.toJson()['classification'], 'manual_port_required');
    expect(result.suggestedMcpServerLine, isNull);
    expect(result.unsupported, isNotEmpty);
  });

  test('rejects traversal paths before decoding entry contents', () {
    final zip = makeZip(<String, String>{'../escape/package.json': '{}'});
    expect(
      () => DshBundleArchiveInspector.inspectBytes(zip, bundleName: 'bad'),
      throwsFormatException,
    );
  });

  test('rejects invalid and oversized archive input', () {
    expect(
      () => DshBundleArchiveInspector.inspectBytes(<int>[1, 2],
          bundleName: 'bad'),
      throwsFormatException,
    );
    expect(
      () => DshBundleArchiveInspector.inspectBytes(
        List<int>.filled(DshBundleArchiveInspector.maxArchiveBytes + 1, 0),
        bundleName: 'large',
      ),
      throwsFormatException,
    );
  });
}
