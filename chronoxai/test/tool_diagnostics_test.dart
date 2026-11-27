import 'dart:io';

import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/tool_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolDiagnostic', () {
    test('classifies missing commands and gives a bounded recovery path', () {
      final result = ToolDiagnostic.fromMessage(
        toolName: 'bash',
        message: 'python: command not found',
      );

      expect(result.kind, ToolFailureKind.missingExecutable);
      expect(result.recoveryHint, contains('command -v'));
      expect(result.recoveryHint, contains('política de aprobación'));
    });

    test('classifies timeouts, permissions, paths, and process exits', () {
      expect(
        ToolDiagnostic.fromMessage(
          toolName: 'bash',
          message: 'command timed out',
        ).kind,
        ToolFailureKind.timeout,
      );
      expect(
        ToolDiagnostic.fromMessage(
          toolName: 'write',
          message: 'Permission denied',
        ).kind,
        ToolFailureKind.permissionDenied,
      );
      expect(
        ToolDiagnostic.fromMessage(
          toolName: 'read',
          message: 'No such file or directory',
        ).kind,
        ToolFailureKind.missingPath,
      );
      expect(
        ToolDiagnostic.fromMessage(
          toolName: 'read',
          message: 'La ruta intenta salir del workspace',
        ).kind,
        ToolFailureKind.pathOutsideWorkspace,
      );
      final failedProcess = ToolDiagnostic.fromMessage(
        toolName: 'bash',
        message: 'compiler failed',
        metadata: <String, Object?>{'exitCode': 2},
      );
      expect(failedProcess.kind, ToolFailureKind.processFailed);
      expect(failedProcess.exitCode, 2);
      expect(
        ToolDiagnostic.fromMessage(
          toolName: 'bash',
          message: 'shell returned 127',
          metadata: <String, Object?>{'exitCode': 127},
        ).kind,
        ToolFailureKind.missingExecutable,
      );
    });

    test('maps platform exceptions without exposing arguments or secrets', () {
      final result = ToolDiagnostic.fromException(
        const ProcessException('git', <String>['push'], 'fatal: secret token'),
        toolName: 'bash',
      );

      expect(result.kind, ToolFailureKind.missingExecutable);
      expect(result.recoveryHint, isNot(contains('secret token')));
    });
  });

  test('tool result diagnostics survive JSONL round trips and old records', () {
    const result = ToolResultEvent(
      callId: 'c1',
      name: 'bash',
      content: 'falló',
      isError: true,
      errorCategory: 'missing_executable',
      recoveryHint: 'Comprueba command -v.',
      exitCode: 127,
    );
    final restored = ToolResultEvent.fromJson(result.toJson());
    expect(restored.errorCategory, 'missing_executable');
    expect(restored.recoveryHint, 'Comprueba command -v.');
    expect(restored.exitCode, 127);

    final oldFormat = ToolResultEvent.fromJson(const <String, Object?>{
      'callId': 'old',
      'name': 'read',
      'content': 'ok',
    });
    expect(oldFormat.errorCategory, isNull);
    expect(oldFormat.exitCode, isNull);
  });
}
