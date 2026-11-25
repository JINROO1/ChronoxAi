import 'package:chronoxai/domain/agent/workspace_index.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:flutter_test/flutter_test.dart';

class _IndexFileSystem implements FileSystemSeam {
  final Map<String, String> files = <String, String>{};
  final List<String> reads = <String>[];
  @override
  Future<bool> exists(String path) async => files.containsKey(path);
  @override
  Future<List<String>> glob(String pattern) async => files.keys.toList();
  @override
  Future<List<String>> grep(String pattern, {String? path}) async =>
      const <String>[];
  @override
  Future<List<String>> list(String path) async => const <String>[];
  @override
  Future<String> readFile(String path) async {
    reads.add(path);
    final content = files[path];
    if (content == null) throw StateError('missing: $path');
    return content;
  }

  @override
  Future<void> writeFile(String path, String content) async {
    files[path] = content;
  }
}

void main() {
  late _IndexFileSystem fileSystem;
  late WorkspaceIndex index;

  setUp(() {
    fileSystem = _IndexFileSystem();
    index = WorkspaceIndex(fileSystem);
  });

  test('extracts approximate symbols and imports across language fixtures',
      () async {
    fileSystem.files.addAll(<String, String>{
      '/workspace/lib/app.dart': "import 'package:core/core.dart';\n"
          'class CheckoutService {}\n'
          'void submitOrder() {}\n',
      '/workspace/src/client.ts': "import { Router } from 'router-lib';\n"
          'export function launchApp() {}\n',
      '/workspace/python/app.py': 'from package.core import Thing\n'
          'class CheckoutHandler:\n'
          '    pass\n'
          'def submit_order():\n'
          '    pass\n',
      '/workspace/cmd/main.go': 'package main\n'
          'import "net/http"\n'
          'func Serve() {}\n',
      '/workspace/src/lib.rs': 'use std::collections::HashMap;\n'
          'pub struct Store {}\n'
          'pub fn save_item() {}\n',
    });

    await index.refresh();

    expect(index.fileCount, 5, reason: index.skippedPaths.join('; '));
    expect(index.symbols(query: 'Checkout').map((final s) => s.name),
        containsAll(<String>['CheckoutService', 'CheckoutHandler']));
    expect(index.symbols(query: 'submit').map((final s) => s.name),
        containsAll(<String>['submitOrder', 'submit_order']));
    expect(index.imports(query: 'core').map((final i) => i.source),
        contains('package.core'));
    expect(index.imports(query: 'router').single.source, 'router-lib');
    expect(index.symbols().every((final s) => s.approximate), isTrue);
  });

  test('returns exact references with stable one-based ranges', () async {
    fileSystem.files['/workspace/lib/use.dart'] = 'final cart = createCart();\n'
        'cart.checkout();\n'
        'cartoon();\n';

    await index.refresh();
    final references = index.references('cart');

    expect(references, hasLength(2));
    expect(references.first.path, '/workspace/lib/use.dart');
    expect(references.first.line, 1);
    expect(references.first.column, 7);
    expect(references.last.line, 2);
    expect(() => index.references('cart()'), throwsArgumentError);
  });

  test('incremental refresh reparses changed files and removes deleted files',
      () async {
    fileSystem.files['/workspace/a.dart'] = 'class Before {}';
    await index.refresh();
    expect(index.updatedFiles, 1);
    expect(index.symbols(query: 'Before'), hasLength(1));

    await index.refresh();
    expect(index.updatedFiles, 0);
    expect(fileSystem.reads, hasLength(2));

    fileSystem.files['/workspace/a.dart'] = 'class After {}';
    fileSystem.files.remove('/workspace/a.dart');
    fileSystem.files['/workspace/b.dart'] = 'class NewEntry {}';
    await index.refresh();

    expect(index.updatedFiles, 1);
    expect(index.symbols(query: 'Before'), isEmpty);
    expect(index.symbols(query: 'NewEntry'), hasLength(1));
  });

  test('excludes generated/vendor trees and enforces file/character budgets',
      () async {
    fileSystem.files['/workspace/node_modules/pkg/index.js'] =
        'class Hidden {}';
    fileSystem.files['/workspace/build/generated.dart'] = 'class Hidden {}';
    fileSystem.files['/workspace/lib/huge.dart'] =
        List<String>.filled(70000, 'x').join();
    for (var index = 0; index < WorkspaceIndex.maxFiles + 3; index++) {
      fileSystem.files['/workspace/src/f$index.dart'] = 'class C$index {}';
    }

    await index.refresh();

    expect(index.fileCount, lessThanOrEqualTo(WorkspaceIndex.maxFiles));
    expect(index.truncated, isTrue);
    expect(index.skippedFiles, greaterThan(0));
    expect(index.cachedCharacters,
        lessThanOrEqualTo(WorkspaceIndex.maxTotalCharacters));
    expect(index.symbols(query: 'Hidden'), isEmpty);
    expect(index.symbols(query: 'C'), isNotEmpty);
  });
}
