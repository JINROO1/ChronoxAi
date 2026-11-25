import 'dart:async';
import 'dart:io';

/// Stable, model-visible categories for recoverable tool failures.
enum ToolFailureKind {
  invalidArguments('invalid_arguments'),
  missingExecutable('missing_executable'),
  missingPath('missing_path'),
  pathOutsideWorkspace('path_outside_workspace'),
  permissionDenied('permission_denied'),
  timeout('timeout'),
  network('network'),
  policyDenied('policy_denied'),
  processFailed('process_failed'),
  repeatedFailure('repeated_failure'),
  toolError('tool_error');

  const ToolFailureKind(this.jsonName);
  final String jsonName;
}

class ToolDiagnostic {
  const ToolDiagnostic({
    required this.kind,
    required this.recoveryHint,
    this.exitCode,
  });

  final ToolFailureKind kind;
  final String recoveryHint;
  final int? exitCode;

  static ToolDiagnostic fromException(
    final Object error, {
    required final String toolName,
  }) {
    if (error is TimeoutException) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.timeout,
        recoveryHint:
            'Reduce el alcance o aumenta el timeout de forma razonable; '
            'para procesos persistentes consulta la terminal incremental.',
      );
    }
    if (error is ProcessException) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.missingExecutable,
        recoveryHint:
            'Comprueba qué ejecutable falta con command -v. Si no está '
            'instalado, instala el paquete mínimo respetando la política activa.',
      );
    }
    if (error is SocketException || error is HttpException) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.network,
        recoveryHint:
            'Comprueba conectividad, URL y configuración. Reintenta como '
            'máximo una vez si el fallo parece transitorio.',
      );
    }
    if (error is FileSystemException) {
      final text = error.message.toLowerCase();
      if (text.contains('permission') || text.contains('denied')) {
        return const ToolDiagnostic(
          kind: ToolFailureKind.permissionDenied,
          recoveryHint:
              'Comprueba la ruta y permisos del workspace; no recurras a sudo '
              'ni amplíes el acceso sin una razón verificada.',
        );
      }
      return const ToolDiagnostic(
        kind: ToolFailureKind.missingPath,
        recoveryHint:
            'Confirma la ruta con file_exists/list_dir y corrige el path; crea '
            'el archivo o directorio solo si la tarea lo requiere.',
      );
    }
    return fromMessage(toolName: toolName, message: error.toString());
  }

  static ToolDiagnostic fromMessage({
    required final String toolName,
    required final String message,
    final Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final text = message.toLowerCase();
    final rawExitCode = metadata['exitCode'];
    final code = rawExitCode is num ? rawExitCode.toInt() : null;
    if (text.contains('argumentos inválidos') ||
        text.contains('invalid argument') ||
        text.contains('falta el campo requerido')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.invalidArguments,
        recoveryHint:
            'Compara los argumentos con el esquema de la herramienta, corrige '
            'los tipos/campos y vuelve a intentarlo una sola vez.',
      );
    }
    if (text.contains('rechazó') ||
        text.contains('rejected') ||
        text.contains('bloqueada') ||
        text.contains('blocked by policy')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.policyDenied,
        recoveryHint:
            'No intentes eludir la política usando otra herramienta. Espera '
            'aprobación o pide al usuario cambiar el permiso.',
      );
    }
    if (text.contains('timeout') ||
        text.contains('timed out') ||
        text.contains('tiempo máximo')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.timeout,
        recoveryHint:
            'Reduce el alcance, divide la tarea o aumenta el timeout con '
            'prudencia; no repitas el mismo proceso sin cambios.',
      );
    }
    if (text.contains('permission denied') ||
        text.contains('permissiondenied') ||
        text.contains('acceso denegado') ||
        text.contains('operation not permitted')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.permissionDenied,
        recoveryHint:
            'Verifica ruta, permisos y aislamiento. No uses sudo ni cambies '
            'permisos de forma recursiva como primer intento.',
      );
    }
    if (text.contains('command not found') ||
        text.contains('executable file not found') ||
        text.contains('not found in path') ||
        (toolName == 'bash' && text.contains('no such file or directory'))) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.missingExecutable,
        recoveryHint:
            'Identifica el ejecutable exacto con command -v y consulta el gestor '
            'de paquetes de la distribución. Instala solo lo necesario bajo la '
            'política de aprobación activa y reintenta.',
      );
    }
    if (text.contains('fuera de /workspace') ||
        text.contains('intenta salir del workspace') ||
        text.contains('outside the workspace')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.pathOutsideWorkspace,
        recoveryHint:
            'Usa una ruta dentro de /workspace. No intentes acceder a archivos '
            'del dispositivo fuera del workspace.',
      );
    }
    if (text.contains('no such file') ||
        text.contains('does not exist') ||
        text.contains('no existe') ||
        text.contains('not a directory')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.missingPath,
        recoveryHint:
            'Comprueba la ruta con file_exists/list_dir, distingue archivo de '
            'directorio y corrige el path antes de repetir la operación.',
      );
    }
    if (text.contains('socketexception') ||
        text.contains('httpexception') ||
        text.contains('connection refused') ||
        text.contains('connection reset') ||
        text.contains('network is unreachable') ||
        text.contains('dns')) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.network,
        recoveryHint:
            'Comprueba conectividad, URL, DNS y credenciales sin exponer '
            'secretos. Reintenta una vez si el error es transitorio.',
      );
    }
    if (code == 124 || code == 137) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.timeout,
        exitCode: 124,
        recoveryHint:
            'El proceso alcanzó el límite de tiempo. Reduce el alcance, aumenta '
            'el timeout con prudencia o usa una terminal persistente.',
      );
    }
    if (code == 126) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.permissionDenied,
        exitCode: 126,
        recoveryHint:
            'El comando existe pero no se pudo ejecutar. Comprueba permisos y '
            'formato del ejecutable; no cambies permisos a ciegas.',
      );
    }
    if (code == 127) {
      return const ToolDiagnostic(
        kind: ToolFailureKind.missingExecutable,
        exitCode: 127,
        recoveryHint:
            'El shell no encontró el comando. Comprueba command -v y, si falta, '
            'instala el paquete mínimo según la política activa.',
      );
    }
    if (code != null && code != 0) {
      return ToolDiagnostic(
        kind: ToolFailureKind.processFailed,
        exitCode: code,
        recoveryHint:
            'Lee stderr y el código de salida ($code), identifica la causa y '
            'cambia el comando o el entorno antes de volver a ejecutarlo.',
      );
    }
    return const ToolDiagnostic(
      kind: ToolFailureKind.toolError,
      recoveryHint:
          'Inspecciona el error y los argumentos; intenta una alternativa '
          'distinta en vez de repetir sin cambios.',
    );
  }
}
