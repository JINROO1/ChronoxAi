/// Contratos de las capacidades intercambiables del sistema.
///
/// Equivalen a los *seams* de DeepSeek Harness (`ctx.fs`, `ctx.shell`,
/// `ctx.llm`…): una definición, una implementación y un consumidor, de modo que
/// sustituir dónde se ejecuta algo no obligue a tocar los consumidores.
///
/// Viven en su propio fichero, sin dependencias del resto del dominio, para
/// evitar ciclos: `plugin_api` los consume, `plugin_runtime` implementa el host
/// y la capa de datos aporta las implementaciones reales (proot, PTY, HTTP).
library;

/// `ctx.fs` — acceso al sistema de archivos, confinado al workspace.
abstract class FileSystemSeam {
  Future<String> readFile(String path);
  Future<void> writeFile(String path, String content);
  Future<bool> exists(String path);
  Future<List<String>> list(String path);

  /// Rutas que coinciden con un patrón glob.
  Future<List<String>> glob(String pattern);

  /// Búsqueda de texto; devuelve `ruta:línea:texto`.
  Future<List<String>> grep(String pattern, {String? path});
}

/// `ctx.shell` — ejecución de comandos dentro del contenedor.
abstract class ShellSeam {
  Future<ShellResult> run(
    String command, {
    String? workingDirectory,
    Duration? timeout,
  });
}

class ShellResult {
  const ShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get isSuccess => exitCode == 0;

  /// Salida combinada, que es lo que suele querer ver el modelo.
  String get output {
    if (stderr.isEmpty) return stdout;
    if (stdout.isEmpty) return stderr;
    return '$stdout\n$stderr';
  }
}

/// `ctx.terminals` — terminales persistentes.
abstract class TerminalsSeam {
  Future<String> open({String? title});
  Future<void> send(String terminalId, String input);
  Future<String> read(String terminalId, {int? sinceOffset});
  Future<void> close(String terminalId);
  Future<List<TerminalInfo>> list();
}

class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.title,
    required this.isAlive,
    required this.bytesProduced,
    this.processId,
    this.startedAt,
    this.exitedAt,
    this.exitCode,
    this.outputBaseOffset = 0,
    this.retainedBytes,
    this.outputLimitBytes,
  });

  final String id;
  final String title;
  final bool isAlive;
  /// Total bytes produced during this process lifetime.
  final int bytesProduced;
  /// App-assigned logical process id; it is not an OS PID.
  final int? processId;
  final DateTime? startedAt;
  final DateTime? exitedAt;
  final int? exitCode;
  /// Earliest retained output offset in decoded characters.
  final int outputBaseOffset;
  final int? retainedBytes;
  final int? outputLimitBytes;
}

/// `ctx.llm` — adaptador de modelo.
abstract class LlmSeam {
  /// Una llamada completa (sin streaming) para tareas auxiliares: títulos,
  /// clasificación, compactación de contexto.
  Future<String> complete(String prompt, {String? system});
}

/// `ctx.sessions` — acceso de lectura al log.
abstract class SessionSeam {
  String get sessionId;
  List<Object?> get events;
}

/// Capacidad de red saliente.
abstract class NetworkSeam {
  Future<NetworkResponse> get(Uri uri, {Map<String, String>? headers});

  /// Web research fetch: implementations should disable redirects and enforce
  /// [maxResponseBytes]. The default keeps test/custom seams source-compatible.
  Future<NetworkResponse> getWeb(
    Uri uri, {
    Map<String, String>? headers,
    int maxResponseBytes = 1000000,
  }) =>
      get(uri, headers: headers);
  Future<NetworkResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  });
}

class NetworkResponse {
  const NetworkResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}
