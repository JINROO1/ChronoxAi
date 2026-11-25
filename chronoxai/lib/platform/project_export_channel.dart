import 'package:flutter/services.dart';

/// Android Storage Access Framework destination picker for project ZIP exports.
class ProjectExportChannel {
  const ProjectExportChannel();
  static const MethodChannel _channel = MethodChannel('app.chronoxai/project_export');

  Future<bool> saveZip(String path, String fileName) async =>
      await _channel.invokeMethod<bool>('saveZip', <String, Object?>{
        'path': path,
        'fileName': fileName,
      }) ??
      false;
}
