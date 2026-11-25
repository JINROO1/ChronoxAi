import 'dart:io';

import 'package:chronoxai/domain/agent/project_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory storageDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chronox-memory-test-');
    storageDir = Directory('${tempDir.path}/app-support');
    await storageDir.create(recursive: true);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('persists sourced, dated, confidence-rated entries per workspace',
      () async {
    final store = await ProjectMemoryStore.open(
      workspacePath: '${tempDir.path}/workspace-a',
      storageDirectory: storageDir,
    );
    final entry = await store.add(
      kind: ProjectMemoryKind.fact,
      text: 'The project uses Dart 3.',
      source: 'pubspec.yaml:1',
      confidence: 0.9,
    );

    final reopened = await ProjectMemoryStore.open(
      workspacePath: '${tempDir.path}/workspace-a',
      storageDirectory: storageDir,
    );
    final otherWorkspace = await ProjectMemoryStore.open(
      workspacePath: '${tempDir.path}/workspace-b',
      storageDirectory: storageDir,
    );

    expect(reopened.entries.single.id, entry.id);
    expect(reopened.entries.single.kind, ProjectMemoryKind.fact);
    expect(reopened.entries.single.source, 'pubspec.yaml:1');
    expect(reopened.entries.single.confidence, 0.9);
    expect(reopened.entries.single.createdAt.isUtc, isTrue);
    expect(otherWorkspace.entries, isEmpty);
    expect(reopened.file.path, isNot(otherWorkspace.file.path));
  });

  test('separates fact, preference, and confirmed conversation memory',
      () async {
    final store = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    await store.add(
      kind: ProjectMemoryKind.fact,
      text: 'Uses SQLite for local storage.',
      source: 'docs/storage.md',
      confidence: 0.95,
    );
    await store.add(
      kind: ProjectMemoryKind.preference,
      text: 'Prefers concise, focused diffs.',
      source: 'User confirmed in settings',
      confidence: 0.8,
    );
    await store.add(
      kind: ProjectMemoryKind.conversation,
      text: 'User confirmed that schema migrations require a preview.',
      source: 'User confirmed, 2026-11-23',
      confidence: 1,
    );

    expect(store.entries.map((final entry) => entry.kind), <ProjectMemoryKind>[
      ProjectMemoryKind.fact,
      ProjectMemoryKind.preference,
      ProjectMemoryKind.conversation,
    ]);
  });

  test('rejects likely credentials, duplicates, empty provenance and bad scores',
      () async {
    final store = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );

    Future<void> add(
      final String text, {
      String source = 'user-confirmed',
      double confidence = 0.7,
    }) async {
      await store.add(
        kind: ProjectMemoryKind.fact,
        text: text,
        source: source,
        confidence: confidence,
      );
    }

    await expectLater(add('API key: sk-12345678901234567890'), throwsArgumentError);
    await expectLater(add('Valid fact', source: '  '), throwsArgumentError);
    await expectLater(add('Valid fact', confidence: 1.2), throwsArgumentError);
    await add('Uses a local SQLite database.');
    await expectLater(add('Uses a local SQLite database.'), throwsStateError);
  });

  test('ranks relevant entries, enforces exclusions, toggle and context budget',
      () async {
    final store = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    await store.add(
      kind: ProjectMemoryKind.fact,
      text: 'The payments module uses Stripe test fixtures.',
      source: 'lib/payments/client.dart',
      confidence: 0.95,
    );
    await store.add(
      kind: ProjectMemoryKind.preference,
      text: 'For payments, always use deterministic fake clients.',
      source: 'User confirmed',
      confidence: 0.9,
    );
    await store.add(
      kind: ProjectMemoryKind.fact,
      text: 'The UI uses a 12 pixel spacing scale.',
      source: 'design.md',
      confidence: 0.8,
    );

    final relevant = store.contextFor('Fix the payments client tests');
    expect(relevant, contains('Stripe test fixtures'));
    expect(relevant, contains('deterministic fake clients'));
    expect(relevant, isNot(contains('12 pixel spacing')));
    expect(relevant.length, lessThanOrEqualTo(ProjectMemoryStore.maxContextCharacters));

    await store.configure(
      enabled: true,
      excludedTopics: <String>['payments'],
      excludedSources: <String>['design.md'],
    );
    expect(store.contextFor('Fix the payments client tests'), isEmpty);
    expect(store.exportJson(), contains('excludedTopics'));

    await store.configure(
      enabled: false,
      excludedTopics: const <String>[],
      excludedSources: const <String>[],
    );
    expect(store.contextFor('payments'), isEmpty);
    final reloaded = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    expect(reloaded.enabled, isFalse);
  });

  test('corrupt storage fails open without injecting or overwriting until reset',
      () async {
    final initial = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    await initial.file.writeAsString('{not-json');

    final reopened = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    expect(reopened.loadWarning, isNotNull);
    expect(reopened.contextFor('anything'), isEmpty);
    await expectLater(
      reopened.add(
        kind: ProjectMemoryKind.fact,
        text: 'A fact',
        source: 'notes',
        confidence: 0.8,
      ),
      throwsStateError,
    );

    await reopened.clear();
    expect(reopened.canWrite, isTrue);
    expect(await reopened.file.exists(), isFalse);
  });

  test('rejects unsupported versions and filters unsafe entries on load',
      () async {
    final store = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    await store.file.writeAsString('''
{
  "version": 1,
  "entries": [
    {
      "id": "credential",
      "kind": "fact",
      "text": "password: exposed-value",
      "source": "manual",
      "createdAt": "2026-11-23T00:00:00.000Z",
      "confidence": 1.0
    },
    {
      "id": "valid",
      "kind": "fact",
      "text": "Uses a local cache.",
      "source": "README.md",
      "createdAt": "2026-11-23T00:00:00.000Z",
      "confidence": 0.8
    }
  ]
}
''');

    final reopened = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    expect(reopened.entries, hasLength(1));
    expect(reopened.rejectedOnLoad, 1);
    expect(reopened.contextFor('cache'), isNot(contains('exposed-value')));

    await reopened.file.writeAsString('{"version": 999, "entries": []}');
    final futureVersion = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    expect(futureVersion.loadWarning, isNotNull);
    expect(futureVersion.entries, isEmpty);
  });

  test('supports editing, export, deletion, and deleting all data', () async {
    final store = await ProjectMemoryStore.open(
      workspacePath: tempDir.path,
      storageDirectory: storageDir,
    );
    final entry = await store.add(
      kind: ProjectMemoryKind.fact,
      text: 'Uses package A.',
      source: 'pubspec.yaml',
      confidence: 0.6,
    );
    await store.update(
      entry.id,
      kind: ProjectMemoryKind.preference,
      text: 'Prefers package B.',
      source: 'User confirmed',
      confidence: 0.9,
    );
    expect(store.entries.single.kind, ProjectMemoryKind.preference);
    expect(store.exportJson(), contains('Prefers package B.'));

    await store.remove(entry.id);
    expect(store.entries, isEmpty);
    await store.add(
      kind: ProjectMemoryKind.fact,
      text: 'A removable note.',
      source: 'README.md',
      confidence: 0.5,
    );
    await store.clear();
    expect(store.entries, isEmpty);
    expect(await store.file.exists(), isFalse);
  });
}
