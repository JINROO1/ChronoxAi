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
  LocalLlmProvider(this.engine, {this.modelFileResolver});

  final LocalInferenceEngine engine;
  final Future<File?> Function()? modelFileResolver;
  bool _generating = false;

  @override
  String get name => 'Qwen local (en el dispositivo)';

  @override
  String get model => engine.model;

  @override
  int? get contextWindow => engine.contextWindow;

  Future<void> loadModel(File file) => engine.load(file);

  Future<void> unloadModel() => engine.unload();

  Future<void> dispose() async {
    await engine.cancel();
    await engine.unload();
  }

  @override
  Stream<LlmChunk> stream({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  }) {
    if (tools.isNotEmpty) {
      return Stream<LlmChunk>.error(const LlmException(
        LlmErrorKind.unknown,
        'El proveedor local aún no admite llamadas a herramientas; no se ejecutó ninguna.',
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
          if (!engine.isLoaded) {
            final file = await modelFileResolver?.call();
            if (file == null) {
              throw const LlmException(
                LlmErrorKind.unknown,
                'No hay un modelo local instalado o seleccionado.',
              );
            }
            await engine.load(file);
          }
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
        // Keep the provider busy until onListen's finally block runs. Native
        // cancellation is asynchronous; releasing the guard here could admit a
        // second request while the first JNI call still owns the context.
        await engine.cancel();
      },
    );
    return controller.stream;
  }
}
