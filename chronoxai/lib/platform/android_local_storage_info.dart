import 'dart:io';

import 'package:flutter/services.dart';

/// Small Android-only query for user-visible internal storage availability.
/// Model transfers still validate exact size and digest in LocalModelStore.
class AndroidLocalStorageInfo {
  const AndroidLocalStorageInfo({
    MethodChannel channel = const MethodChannel('app.chronoxai/local_llm'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<int?> availableBytes() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<int>('availableStorageBytes');
  }

  /// Process/device memory facts for the on-device acceptance checklist.
  /// Values are byte counts, except [apiLevel] and the ABI label.
  Future<Map<String, Object?>?> diagnostics() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMapMethod<String, Object?>('deviceDiagnostics');
  }
}
