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
    await engine.load(File(modelPath));
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
          .timeout(const Duration(minutes: 10));
      expect(chunks, isNotEmpty);
      expect(chunks.join().trim(), isNotEmpty);
    } finally {
      await engine.unload();
    }
    expect(tester, isNotNull);
  });
}
