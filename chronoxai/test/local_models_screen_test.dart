import 'package:chronoxai/data/llm/local_model_store.dart';
import 'package:chronoxai/ui/settings/local_models_screen.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeModelStore extends LocalModelStore {
  _FakeModelStore() : super(supportDirectory: () async => Directory('/unused'));

  final List<LocalModelInstallation> installed = <LocalModelInstallation>[];
  Completer<LocalModelInstallation>? pendingDownload;
  bool failNextDownload = false;
  bool failVerification = false;
  int removeCalls = 0;
  bool downloadCancelled = false;

  @override
  Future<List<LocalModelInstallation>> installedModels() async => installed;

  @override
  Future<File?> fileForId(String id) async {
    if (failVerification) {
      throw const FileSystemException('SHA-256 no coincide');
    }
    for (final item in installed) {
      if (item.spec.id == id) return item.file;
    }
    return null;
  }

  @override
  Future<LocalModelInstallation> download(
    LocalModelSpec spec, {
    void Function(ModelTransferProgress progress)? onProgress,
  }) {
    onProgress?.call(
      ModelTransferProgress(received: spec.bytes ~/ 3, total: spec.bytes),
    );
    final completer = Completer<LocalModelInstallation>();
    pendingDownload = completer;
    if (failNextDownload) {
      failNextDownload = false;
      completer.completeError(const FileSystemException('fallo de red'));
    }
    return completer.future;
  }

  void completeDownload(LocalModelSpec spec) {
    final installation = LocalModelInstallation(
      spec: spec,
      file: File('/unused/${spec.fileName}'),
    );
    installed.add(installation);
    pendingDownload!.complete(installation);
  }

  @override
  void cancelDownload() {
    downloadCancelled = true;
    final pending = pendingDownload;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const FileSystemException('descarga cancelada'));
    }
  }

  @override
  Future<void> remove(LocalModelSpec spec) async {
    removeCalls++;
    installed.removeWhere((final item) => item.spec.id == spec.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget buildScreen({
    required int availableBytes,
    LocalModelStore? store,
  }) =>
      ProviderScope(
        child: MaterialApp(
          home: LocalModelsScreen(
            store: store ?? LocalModelStore(),
            loadInstalledModels: store == null
                ? () async => const <LocalModelInstallation>[]
                : store.installedModels,
            availableStorageBytes: () async => availableBytes,
          ),
        ),
      );

  Future<void> pumpScreen(WidgetTester tester) async {
    // The diagnostics card makes the page taller; keep the interactive controls
    // inside the widget-test viewport rather than attempting taps below it.
    if (tester.view.physicalSize != const Size(1000, 1800)) {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('shows pinned Qwen provenance and RAM caveat',
      (final tester) async {
    await tester
        .pumpWidget(buildScreen(availableBytes: 8 * 1024 * 1024 * 1024));
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Qwen3.5 2B · Q4_K_M'));
    await pumpScreen(tester);

    expect(find.text('Qwen3.5 0.8B · Q4_K_M'), findsOneWidget);
    expect(find.text('Qwen3.5 2B · Q4_K_M'), findsOneWidget);
    expect(find.textContaining('Apache-2.0'), findsNWidgets(2));
    expect(find.textContaining('SHA-256 bd258782e35f'), findsOneWidget);
    expect(find.textContaining('SHA-256 aaf42c8b7c3c'), findsOneWidget);
    expect(find.textContaining('no están certificados'), findsOneWidget);
    expect(find.text('Descargar'), findsNWidgets(2));
  });

  testWidgets('blocks download and explains insufficient storage',
      (final tester) async {
    await tester.pumpWidget(buildScreen(availableBytes: 1024));
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Descargar').first);
    await tester.tap(find.text('Descargar').first);
    await pumpScreen(tester);

    expect(find.textContaining('Espacio insuficiente'), findsOneWidget);
  });
  testWidgets('shows installing, ready, selected, and protected-in-use states',
      (final tester) async {
    final store = _FakeModelStore();
    await tester.pumpWidget(buildScreen(
      availableBytes: 8 * 1024 * 1024 * 1024,
      store: store,
    ));
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Descargar').first);
    await tester.tap(find.text('Descargar').first);
    await pumpScreen(tester);

    expect(store.pendingDownload, isNotNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Cancelar descarga'), findsOneWidget);

    store.completeDownload(LocalModelSpec.catalog.first);
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Usar localmente'));
    expect(find.text('Usar localmente'), findsOneWidget);

    await tester.tap(find.text('Usar localmente'));
    await pumpScreen(tester);
    expect(find.text('En uso'), findsOneWidget);

    await tester.ensureVisible(find.text('Eliminar'));
    await tester.tap(find.text('Eliminar'));
    await pumpScreen(tester);
    expect(find.textContaining('Selecciona otro proveedor o modelo'),
        findsOneWidget);
    expect(store.removeCalls, 0);
  });

  testWidgets('refuses to activate an installation that fails re-verification',
      (final tester) async {
    final store = _FakeModelStore()..failVerification = true;
    store.installed.add(LocalModelInstallation(
      spec: LocalModelSpec.catalog.first,
      file: File('/unused/corrupt.gguf'),
    ));
    await tester.pumpWidget(buildScreen(
      availableBytes: 8 * 1024 * 1024 * 1024,
      store: store,
    ));
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Usar localmente'));
    await tester.tap(find.text('Usar localmente'));
    await pumpScreen(tester);

    expect(find.textContaining('SHA-256 no coincide'), findsOneWidget);
    expect(find.text('Usar localmente'), findsOneWidget);
  });

  testWidgets('cancels an active download and restores retry action',
      (final tester) async {
    final store = _FakeModelStore();
    await tester.pumpWidget(buildScreen(
      availableBytes: 8 * 1024 * 1024 * 1024,
      store: store,
    ));
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Descargar').first);
    await tester.tap(find.text('Descargar').first);
    await pumpScreen(tester);
    await tester.tap(find.text('Cancelar descarga'));
    await pumpScreen(tester);

    expect(store.downloadCancelled, isTrue);
    expect(find.text('Descargar'), findsNWidgets(2));
    expect(find.textContaining('descarga cancelada'), findsOneWidget);
  });

  testWidgets('renders a failed-download error and restores retry action',
      (final tester) async {
    final store = _FakeModelStore()..failNextDownload = true;
    await tester.pumpWidget(buildScreen(
      availableBytes: 8 * 1024 * 1024 * 1024,
      store: store,
    ));
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Descargar').first);
    await tester.tap(find.text('Descargar').first);
    await pumpScreen(tester);

    expect(find.textContaining('fallo de red'), findsOneWidget);
    expect(find.text('Descargar'), findsNWidgets(2));
  });
}
