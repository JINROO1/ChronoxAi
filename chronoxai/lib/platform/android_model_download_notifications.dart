import 'dart:io';

import 'package:flutter/services.dart';

import '../data/llm/local_model_store.dart';

/// Best-effort Android system notification for a model transfer. The in-app
/// transfer state remains available if notifications are denied or unsupported.
class AndroidModelDownloadNotifications {
  const AndroidModelDownloadNotifications();

  static const MethodChannel _channel =
      MethodChannel('app.chronoxai/model_download_notifications');

  Future<bool> start(String modelName) async {
    if (!Platform.isAndroid) return true;
    try {
      final started =
          await _channel.invokeMethod<bool>('start', <String, Object?>{
        'title': 'Descargando $modelName',
      });
      return started ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> showProgress(
    String modelName,
    ModelTransferProgress progress,
  ) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('progress', <String, Object?>{
        'title': 'Descargando $modelName',
        'received': progress.received,
        'total': progress.total,
      });
    } on MissingPluginException {
      // Older/test Flutter engines may not register this optional channel.
    } on PlatformException {
      // A disabled notification permission must not interrupt the download.
    }
  }

  Future<void> showFinished(String modelName) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('finished', <String, Object?>{
        'title': 'Modelo listo',
        'message': '$modelName se descargó y verificó correctamente.',
      });
    } on MissingPluginException {
      // Notification support is optional.
    } on PlatformException {
      // Notification support is optional.
    }
  }

  Future<void> showFailed(String modelName, String message) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('failed', <String, Object?>{
        'title': 'Descarga interrumpida',
        'message': '$modelName: $message',
      });
    } on MissingPluginException {
      // Notification support is optional.
    } on PlatformException {
      // Notification support is optional.
    }
  }
}
