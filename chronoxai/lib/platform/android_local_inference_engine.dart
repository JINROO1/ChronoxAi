import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../data/llm/local_llm_provider.dart';
import '../domain/llm/llm_types.dart';

class LocalGenerationMetrics {
  const LocalGenerationMetrics({
    required this.generatedTokens,
    required this.elapsedMilliseconds,
  });

  final int generatedTokens;
  final int elapsedMilliseconds;

  double get tokensPerSecond => elapsedMilliseconds <= 0
      ? 0
      : generatedTokens * 1000 / elapsedMilliseconds;
}

/// Android MethodChannel/EventChannel bridge to the embedded llama.cpp JNI
/// implementation. It sends no HTTP requests and keeps one native context.
class AndroidLocalInferenceEngine implements LocalInferenceEngine {
  AndroidLocalInferenceEngine({
    this.model = 'Qwen3.5-0.8B-Q4_K_M',
    MethodChannel methodChannel =
        const MethodChannel('app.chronoxai/local_llm'),
    EventChannel eventChannel =
        const EventChannel('app.chronoxai/local_llm_events'),
    this.contextSize = 262144,
    this.threads = 4,
  })  : _methodChannel = methodChannel,
        _eventChannel = eventChannel;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final int contextSize;
  final int threads;
  bool _loaded = false;
  bool _generating = false;
  Duration? _lastLoadDuration;
  LocalGenerationMetrics? _lastGenerationMetrics;

  Duration? get lastLoadDuration => _lastLoadDuration;
  LocalGenerationMetrics? get lastGenerationMetrics => _lastGenerationMetrics;

  @override
  final String model;

  @override
  int? get contextWindow => contextSize;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load(File modelFile) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
          'La inferencia local nativa solo está disponible en Android.');
    }
    if (!await modelFile.exists()) {
      throw FileSystemException(
          'No se encontró el archivo GGUF.', modelFile.path);
    }
    if (_loaded) await unload();
    final stopwatch = Stopwatch()..start();
    await _methodChannel.invokeMethod<void>('loadModel', <String, Object?>{
      'path': modelFile.path,
      'contextSize': contextSize,
      'threads': threads,
    });
    stopwatch.stop();
    _lastLoadDuration = stopwatch.elapsed;
    _loaded = true;
  }

  @override
  Stream<String> generate({
    required List<LlmMessage> messages,
    required List<Map<String, Object?>> tools,
    double? temperature,
    int? maxTokens,
  }) {
    if (!_loaded) {
      return Stream<String>.error(
          StateError('No hay un modelo local cargado.'));
    }
    if (_generating) {
      return Stream<String>.error(
          StateError('Ya hay una generación local en curso.'));
    }
    // This text-only spike intentionally does not serialize tool schemas to the
    // native side. Tool execution stays disabled until the dedicated validation
    // phase adds strict parsing and approval integration.
    _generating = true;
    late final StreamController<String> controller;
    StreamSubscription<Object?>? eventSubscription;
    var finished = false;

    Future<void> finishWithError(Object error, [StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      _generating = false;
      if (!controller.isClosed) controller.addError(error, stackTrace);
      await eventSubscription?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<String>(
      onListen: () {
        eventSubscription = _eventChannel.receiveBroadcastStream().listen(
          (final Object? event) {
            if (event is! Map) return;
            switch (event['type']) {
              case 'text':
                final text = event['text'];
                if (text is String && text.isNotEmpty) controller.add(text);
              case 'metrics':
                final tokens = event['tokens'];
                final elapsedMs = event['elapsedMs'];
                if (tokens is int && elapsedMs is int) {
                  _lastGenerationMetrics = LocalGenerationMetrics(
                    generatedTokens: tokens,
                    elapsedMilliseconds: elapsedMs,
                  );
                }
              case 'done':
                if (finished) return;
                finished = true;
                _generating = false;
                unawaited(eventSubscription?.cancel());
                unawaited(controller.close());
              case 'error':
                unawaited(finishWithError(
                  StateError(event['message']?.toString() ??
                      'Falló la inferencia local.'),
                ));
            }
          },
          onError: (final Object error, final StackTrace stackTrace) {
            unawaited(finishWithError(error, stackTrace));
          },
          onDone: () {
            if (!finished)
              unawaited(finishWithError(StateError('Canal local cerrado.')));
          },
        );
        unawaited(_startGeneration(messages, temperature, maxTokens)
            .catchError((final Object error, final StackTrace stackTrace) {
          unawaited(finishWithError(error, stackTrace));
        }));
      },
      onCancel: () async {
        if (!finished) {
          finished = true;
          _generating = false;
          await _methodChannel.invokeMethod<void>('cancel');
        }
        await eventSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> _startGeneration(
    List<LlmMessage> messages,
    double? temperature,
    int? maxTokens,
  ) async {
    final roles = messages.map((final message) => message.role.name).toList();
    final contents = messages.map((final message) => message.content).toList();
    await _methodChannel.invokeMethod<void>('generate', <String, Object?>{
      'roles': roles,
      'contents': contents,
      'temperature': temperature ?? 0.7,
      'maxTokens': maxTokens ?? 2048,
    });
  }

  @override
  Future<void> cancel() async {
    if (_loaded) await _methodChannel.invokeMethod<void>('cancel');
  }

  @override
  Future<void> unload() async {
    if (!_loaded) return;
    if (_generating) await cancel();
    await _methodChannel.invokeMethod<void>('unloadModel');
    _loaded = false;
  }
}
