import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:chronoxai/data/llm/local_model_store.dart';
import 'package:flutter_test/flutter_test.dart';

LocalModelSpec _testSpec(List<int> bytes, {String? shaOverride}) =>
    LocalModelSpec(
      id: 'tiny-test-model',
      label: 'Tiny test model',
      fileName: 'tiny-test.gguf',
      bytes: bytes.length,
      sha256: shaOverride ?? sha256.convert(bytes).toString(),
      url: 'https://models.invalid/tiny-test.gguf',
      revision: 'test-revision',
      format: 'GGUF',
      runtime: 'test-runtime',
      quantization: 'test',
      license: 'test',
      contextWindow: 128,
    );

void main() {
  group('LocalModelSpec.catalog', () {
    test('catalog entries provide versionable runtime and license metadata',
        () {
      for (final spec in LocalModelSpec.catalog) {
        final metadata = spec.toManifestEntry();
        expect(metadata['id'], spec.id);
        expect(metadata['fileName'], spec.fileName);
        expect(metadata['format'], 'GGUF');
        expect(metadata['runtime'], contains('llama.cpp@'));
        expect(metadata['bytes'], spec.bytes);
        expect(metadata['sha256'], spec.sha256);
        expect(metadata['quantization'], 'Q4_K_M');
        expect(metadata['license'], 'Apache-2.0');
        expect(metadata['source'], spec.url);
        expect(metadata['revision'], spec.revision);
        expect(metadata['contextWindow'], greaterThan(0));
      }
    });

    test('pins only the requested Qwen 0.8B and 2B variants', () {
      expect(LocalModelSpec.catalog.map((final spec) => spec.id), <String>[
        'qwen35-0.8b-q4km',
        'qwen35-2b-q4km',
      ]);
      expect(LocalModelSpec.catalog.first.bytes, 532517120);
      expect(LocalModelSpec.catalog.last.bytes, 1280835840);
      expect(
          LocalModelSpec.catalog
              .every((final spec) => spec.sha256.length == 64),
          isTrue);
    });
  });

  test('serializes transfers across distinct store instances', () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final directoryGate = Completer<Directory>();
    final firstStore =
        LocalModelStore(supportDirectory: () => directoryGate.future);
    final secondStore = LocalModelStore(supportDirectory: () async => root);
    final pendingImport =
        firstStore.importFile(File('${root.path}/missing.gguf'));

    await expectLater(
      secondStore.download(LocalModelSpec.catalog.first),
      throwsA(isA<StateError>()),
    );
    directoryGate.complete(root);
    await expectLater(pendingImport, throwsA(isA<FileSystemException>()));
    expect(
        await Directory('${root.path}/local_models').list().toList(), isEmpty);
  });

  test('publishes a valid imported model and its versioned manifest', () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = 'small deterministic model fixture'.codeUnits;
    final spec = _testSpec(bytes);
    final source = File('${root.path}/source.gguf')..writeAsBytesSync(bytes);
    final store = LocalModelStore(
      supportDirectory: () async => root,
      catalog: <LocalModelSpec>[spec],
    );

    final installed = await store.importFile(source);
    expect(installed.spec.id, spec.id);
    expect(await installed.file.readAsBytes(), bytes);
    expect((await store.fileForId(spec.id))?.path, installed.file.path);
    final manifest =
        await File('${root.path}/local_models/models.json').readAsString();
    expect(manifest, contains('"schemaVersion":1'));
    expect(manifest, contains(spec.sha256));
  });

  test('removes temporary import and refuses a bad digest', () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = 'corrupt fixture'.codeUnits;
    final wrongSpec = _testSpec(
      bytes,
      shaOverride: sha256.convert('expected bytes'.codeUnits).toString(),
    );
    final source = File('${root.path}/source.gguf')..writeAsBytesSync(bytes);
    final store = LocalModelStore(
      supportDirectory: () async => root,
      catalog: <LocalModelSpec>[wrongSpec],
    );

    await expectLater(
      store.importFile(source),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.installedModels(), isEmpty);
    expect(
        await Directory('${root.path}/local_models').list().toList(), isEmpty);
  });

  test('cancels a model import before it publishes any bytes', () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = 'cancel this import'.codeUnits;
    final source = File('${root.path}/source.gguf')..writeAsBytesSync(bytes);
    final store = LocalModelStore(
      supportDirectory: () async => root,
      catalog: <LocalModelSpec>[_testSpec(bytes)],
    );

    final pending = store.importFile(source);
    store.cancelDownload();
    await expectLater(pending, throwsA(isA<FileSystemException>()));
    expect(await store.installedModels(), isEmpty);
    expect(
        await Directory('${root.path}/local_models').list().toList(), isEmpty);
  });

  test('does not publish an imported file with an unknown size', () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/wrong.gguf')
      ..writeAsStringSync('not a GGUF');
    final store = LocalModelStore(supportDirectory: () async => root);

    await expectLater(
        store.importFile(source), throwsA(isA<FileSystemException>()));
    final installed = await store.installedModels();
    expect(installed, isEmpty);
  });

  test(
      'rejects model specs outside the pinned catalog before filesystem access',
      () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalModelStore(supportDirectory: () async => root);
    const forged = LocalModelSpec(
      id: '../escape',
      label: 'forged',
      fileName: '../escape.gguf',
      bytes: 1,
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      url: 'https://example.invalid/forged',
      revision: 'forged',
      format: 'GGUF',
      runtime: 'forged',
      quantization: 'Q4_K_M',
      license: 'Apache-2.0',
      contextWindow: 2048,
    );

    await expectLater(store.download(forged), throwsArgumentError);
    await expectLater(store.remove(forged), throwsArgumentError);
    expect(await root.list().toList(), isEmpty);
  });

  test('does not treat an unindexed file as an installed model', () async {
    final root = await Directory.systemTemp.createTemp('chronox-local-model-');
    addTearDown(() => root.delete(recursive: true));
    final models = Directory('${root.path}/local_models')..createSync();
    final spec = LocalModelSpec.catalog.first;
    File('${models.path}/${spec.fileName}').writeAsBytesSync(const <int>[]);
    final store = LocalModelStore(supportDirectory: () async => root);

    expect(await store.installedModels(), isEmpty);
  });
}
