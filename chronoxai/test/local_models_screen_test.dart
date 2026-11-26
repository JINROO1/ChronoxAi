import 'package:chronoxai/data/llm/local_model_store.dart';
import 'package:chronoxai/ui/settings/local_models_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget buildScreen({
    required int availableBytes,
  }) =>
      ProviderScope(
        child: MaterialApp(
          home: LocalModelsScreen(
            store: LocalModelStore(),
            loadInstalledModels: () async => const <LocalModelInstallation>[],
            availableStorageBytes: () async => availableBytes,
          ),
        ),
      );

  Future<void> pumpScreen(WidgetTester tester) async {
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('shows pinned Qwen provenance and RAM caveat',
      (final tester) async {
    await tester.pumpWidget(buildScreen(availableBytes: 8 * 1024 * 1024 * 1024));
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
}
