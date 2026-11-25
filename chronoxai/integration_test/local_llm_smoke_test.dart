import 'dart:io';

import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:chronoxai/platform/android_local_inference_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android JNI loads pinned Qwen GGUF and streams generated text',
      (final tester) async {
    const modelPath = String.fromEnvironment('LOCAL_QWEN_MODEL_PATH');
    expect(modelPath, isNotEmpty, reason: 'CI must provide the verified GGUF path.');
    expect(await File(modelPath).length(), 532517120);

    final engine = AndroidLocalInferenceEngine(contextSize: 1024, threads: 4);
    print('JNI_SMOKE: starting model load');
    await engine.load(File(modelPath)).timeout(const Duration(minutes: 5));
    print('JNI_SMOKE: model loaded; starting generation');
    try {
      final chunks = await engine
          .generate(
            messages: const <LlmMessage>[
              LlmMessage.user('Responde en español con un saludo breve.'),
            ],
            tools: const <Map<String, Object?>>[],
            maxTokens: 4,
            temperature: 0,
          )
          .toList()
          .timeout(const Duration(minutes: 5));
      print('JNI_SMOKE: generation finished (${chunks.length} chunks)');
      expect(chunks, isNotEmpty);
      expect(chunks.join().trim(), isNotEmpty);
    } finally {
      print('JNI_SMOKE: unloading model');
      await engine.unload().timeout(const Duration(minutes: 2));
    }
    expect(tester, isNotNull);
  });
}
