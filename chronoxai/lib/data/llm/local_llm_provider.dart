import 'dart:async';
import 'dart:io';

import '../../domain/llm/llm_types.dart';

/// Narrow seam between ChronoxAI's LLM contract and an on-device runtime.
///
/// Implementations must never make network requests. The eventual Android
/// implementation owns the native model/context lifetime and exposes generated
/// tokens incrementally; tests can provide a deterministic fake.
abstract interface class LocalInferenceEngine {
  String get model;
  int? get contextWindow;
  bool get isLoaded;

  Future<void> load(File modelFile);

  Stream<String> generate({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  });

  Future<void> cancel();
  Future<void> unload();
}

/// Adapts a local inference engine to the same streaming contract as remote
/// providers. It deliberately has no fallback path to a network provider.
class LocalLlmProvider implements LlmProvider {
  LocalLlmProvider(this.engine);

  final LocalInferenceEngine engine;
  bool _generating = false;

  @override
  String get name => 'Qwen local (en el dispositivo)';

  @override
  String get model => engine.model;

  @override
  int? get contextWindow => engine.contextWindow;

  Future<void> loadModel(File file) => engine.load(file);

  Future<void> unloadModel() => engine.unload();

  @override
  Stream<LlmChunk> stream({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  }) {
    if (!engine.isLoaded) {
      return Stream<LlmChunk>.error(const LlmException(
        LlmErrorKind.unknown,
        'No hay un modelo local cargado.',
      ));
    }
    if (_generating) {
      return Stream<LlmChunk>.error(const LlmException(
        LlmErrorKind.unknown,
        'Ya hay una generación local en curso.',
      ));
    }

    _generating = true;
    late final StreamController<LlmChunk> controller;
    controller = StreamController<LlmChunk>(
      onListen: () async {
        try {
          await for (final token in engine.generate(
            messages: messages,
            tools: tools,
            temperature: temperature,
            maxTokens: maxTokens,
          )) {
            if (token.isNotEmpty) {
              controller.add(TextChunk(token));
            }
          }
          if (!controller.isClosed) {
            controller.add(const DoneChunk());
          }
        } catch (error, stackTrace) {
          if (!controller.isClosed) controller.addError(error, stackTrace);
        } finally {
          _generating = false;
          if (!controller.isClosed) await controller.close();
        }
      },
      onCancel: () async {
        await engine.cancel();
        _generating = false;
      },
    );
    return controller.stream;
  }
}
