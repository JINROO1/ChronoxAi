import 'dart:io';

import 'package:flutter/services.dart';

/// Android Storage Access Framework bridge for importing a GGUF without broad
/// storage permissions. Android copies the selected URI into temporary app cache;
/// the verified LocalModelStore then moves it into private model storage.
class AndroidModelFilePicker {
  const AndroidModelFilePicker({
    MethodChannel channel = const MethodChannel('app.chronoxai/local_llm'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<File?> pickModel() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('La importación por selector está disponible en Android.');
    }
    final path = await _channel.invokeMethod<String>('pickModelFile');
    if (path == null || path.isEmpty) return null;
    return File(path);
  }
}
