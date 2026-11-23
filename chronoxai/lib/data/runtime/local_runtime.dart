import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/plugins/seams.dart';
import '../../domain/terminal/linux_paths.dart';
import '../../domain/terminal/proot_command.dart';
import '../../platform/android_runtime_channel.dart';

/// Por qué el runtime no puede usarse todavía.
///
/// Se modela como estado y no como excepción porque es la situación **normal**
/// en el primer arranque: la app tiene que poder abrirse, explicar qué falta y
/// ofrecer instalarlo, no morir con un stack trace.
enum RuntimeProblem {
  /// El dispositivo no es Android o el ABI no está soportado.
  unsupportedDevice,

  /// El sistema no deja ejecutar binarios del directorio privado.
  execBlocked,

  /// Los binarios del APK no están extraídos (build sin `jniLibs`).
  missingBinaries,

  /// El rootfs de Debian no está instalado.
  missingRootfs,

  /// El servicio de privilegios de proot no está disponible.
  unavailable,
}

class RuntimeStatus {
  const RuntimeStatus({
    required this.isReady,
    this.problem,
    this.detail = '',
    this.prootPath,
  });

  final bool isReady;
  final RuntimeProblem? problem;
  final String detail;
  final String? prootPath;

  String get title => switch (problem) {
        null => 'Runtime listo',
        RuntimeProblem.unsupportedDevice => 'Dispositivo no compatible',
        RuntimeProblem.execBlocked => 'Android bloquea la ejecución',
        RuntimeProblem.missingBinaries => 'Faltan los binarios de proot',
        RuntimeProblem.missingRootfs => 'Falta el sistema Linux',
        RuntimeProblem.unavailable => 'Runtime no disponible',
      };

  /// `true` si los comandos fallarán pero el resto de la sesión funciona.
  bool get isDegraded => problem == RuntimeProblem.missingRootfs;

  String get message => switch (problem) {
        null => 'El contenedor Linux está instalado y funciona.',
        RuntimeProblem.unsupportedDevice =>
          'Chronox necesita un dispositivo ARM64. Este dispositivo usa otro tipo '
              'de procesador y no puede ejecutar el contenedor.',
        RuntimeProblem.execBlocked =>
          'Este Android impide ejecutar programas desde el almacenamiento de la '
              'app. Suele ocurrir en dispositivos con políticas de seguridad '
              'estrictas o en apps con targetSdk reciente.',
        RuntimeProblem.missingBinaries =>
          'El APK no incluye los binarios de proot. Es un fallo de compilación: '
              'revisa que jniLibs contenga libproot.so y libproot_loader.so.',
        RuntimeProblem.missingRootfs =>
          'Todavía no hay un sistema Linux instalado. Descarga Debian para poder '
              'ejecutar comandos.',
        RuntimeProblem.unavailable =>
          detail.isEmpty ? 'El runtime no está disponible.' : detail,
      };
}

/// Runtime Linux local: `proot` + rootfs de Debian dentro del APK.
///
/// Implementa los seams `shell` y `fileSystem` sobre el contenedor, y expone
/// [status] para que la UI pueda explicar qué falta antes de intentar nada.
class LocalRuntime {
  LocalRuntime({required this.paths, AndroidRuntimeChannel? channel})
      : _channel = channel ?? const AndroidRuntimeChannel();

  final LinuxPaths paths;
  final AndroidRuntimeChannel _channel;

  PlatformFacts? _facts;
  String? _prootPath;
  String? _loaderPath;

  /// Ruta del workspace tal y como se ve **dentro** del contenedor.
  static const String guestWorkspace = '/workspace';

  /// Ruta del workspace en el dispositivo.
  String get hostWorkspace => paths.workspaceDir;

  Future<PlatformFacts> facts() async => _facts ??= await _channel.read();

  /// Comprueba, sin lanzar nada, si el runtime puede usarse.
  Future<RuntimeStatus> status() async {
    final facts = await this.facts();

    if (facts.isAndroid && !facts.isSupportedAbi) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.unsupportedDevice,
        detail: 'ABI detectado: ${facts.abi}.',
      );
    }

    final nativeLibraryDir = facts.nativeLibraryDir;
    if (nativeLibraryDir == null) {
      return const RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingBinaries,
        detail: 'Android no informó del directorio de librerías nativas.',
      );
    }

    final proot = p.join(nativeLibraryDir, 'libproot.so');
    final loader = p.join(nativeLibraryDir, 'libproot_loader.so');
    if (!File(proot).existsSync() || !File(loader).existsSync()) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingBinaries,
        detail: 'Se esperaban $proot y $loader.',
      );
    }
    _prootPath = proot;
    _loaderPath = loader;

    // El rootfs existe si tiene un `/bin/sh` real. Comprobar solo el directorio
    // daría falsos positivos con una descarga a medias.
    final guestShell = File(p.join(paths.rootfsDir, 'bin', 'sh'));
    if (!guestShell.existsSync()) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingRootfs,
        detail: 'Se esperaba ${guestShell.path}.',
      );
    }

    if (facts.appDataExecBlocked) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.execBlocked,
        detail: 'Android ${facts.sdkInt} con targetSdk ${facts.targetSdk}.',
      );
    }

    return RuntimeStatus(isReady: true, prootPath: proot);
  }

  /// Ejecuta un comando dentro del contenedor y espera a que termine.
  ///
  /// Es el camino que usan las herramientas del agente: sin PTY, con la salida
  /// capturada y un tiempo máximo, porque un comando colgado bloquearía el turno
  /// entero.
  Future<ShellResult> run(
    final String command, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final config = await _config(workingDirectory: workingDirectory);
    final args = ProotCommandBuilder.build(
      config,
      inner: <String>['/bin/bash', '-lc', command],
    );
    final env = ProotCommandBuilder.hostEnvironment(
      nativeLibraryDir: p.dirname(config.prootBinary),
      tempDir: paths.tempDir,
      prootLoader: config.prootLoader,
    );

    await Directory(paths.tempDir).create(recursive: true);

    final process = await Process.start(
      config.prootBinary,
      args,
      environment: env,
      workingDirectory: paths.filesDir,
    );

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    // Se recoge el `Future` de `forEach`, no el de `listen`: el de `listen` se
    // completa al suscribirse, no al terminar el stream.
    final outDone =
        process.stdout.transform(utf8.decoder).forEach(stdoutBuffer.write);
    final errDone =
        process.stderr.transform(utf8.decoder).forEach(stderrBuffer.write);

    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout ?? const Duration(minutes: 2),
      onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await Future.wait<void>(<Future<void>>[outDone, errDone]);

    final stderr = timedOut
        ? '${stderrBuffer.toString()}\n[tiempo agotado: el comando se detuvo]'
        : stderrBuffer.toString();

    return ShellResult(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderr.trim(),
    );
  }

  /// Configuración de proot con los montajes del dispositivo.
  Future<ProotConfig> _config({final String? workingDirectory}) async {
    final facts = await this.facts();
    final nativeLibraryDir = facts.nativeLibraryDir;
    if (nativeLibraryDir == null) {
      throw const RuntimeException(
        'No hay directorio de librerías nativas: el APK no incluye proot.',
      );
    }

    final binds = <BindMount>[
      const BindMount('/dev', '/dev'),
      const BindMount('/proc', '/proc'),
      const BindMount('/sys', '/sys'),
      BindMount(paths.workspaceDir, guestWorkspace),
      BindMount(paths.homeDir, '/root'),
      BindMount(paths.tempDir, '/tmp'),
    ];

    return ProotConfig(
      prootBinary: _prootPath ?? p.join(nativeLibraryDir, 'libproot.so'),
      prootLoader:
          _loaderPath ?? p.join(nativeLibraryDir, 'libproot_loader.so'),
      rootfs: paths.rootfsDir,
      workingDirectory: workingDirectory ?? guestWorkspace,
      homeDirectory: '/root',
      bindMounts: binds,
      fakeKernelRelease: ProotCommandBuilder.defaultKernelRelease,
    );
  }

  /// Comando completo para abrir una terminal interactiva (PTY).
  Future<({String binary, List<String> args, Map<String, String> env})>
      interactiveCommand({final String? workingDirectory}) async {
    final config = await _config(workingDirectory: workingDirectory);
    return (
      binary: config.prootBinary,
      args: ProotCommandBuilder.build(config),
      env: ProotCommandBuilder.hostEnvironment(
        nativeLibraryDir: p.dirname(config.prootBinary),
        tempDir: paths.tempDir,
        prootLoader: config.prootLoader,
      ),
    );
  }
}

class RuntimeException implements Exception {
  const RuntimeException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// `ctx.shell` sobre el runtime local.
class ProotShellSeam implements ShellSeam {
  const ProotShellSeam(this.runtime);

  final LocalRuntime runtime;

  @override
  Future<ShellResult> run(
    final String command, {
    final String? workingDirectory,
    final Duration? timeout,
  }) =>
      runtime.run(command,
          workingDirectory: workingDirectory, timeout: timeout);
}

/// Shell de sustitución cuando el runtime todavía no está instalado.
///
/// Devolver un error explicativo es mejor que impedir abrir la sesión: el usuario
/// puede seguir hablando con el agente, leer y escribir ficheros del workspace, y
/// ver exactamente qué falta para poder ejecutar comandos.
class UnavailableShellSeam implements ShellSeam {
  const UnavailableShellSeam(this.status);

  final RuntimeStatus status;

  @override
  Future<ShellResult> run(
    final String command, {
    final String? workingDirectory,
    final Duration? timeout,
  }) async => ShellResult(
    exitCode: 127,
    stdout: '',
    stderr:
        '${status.title}: no se pueden ejecutar comandos todavía.\n'
        '${status.message}',
  );
}

/// `ctx.fs` sobre el workspace del dispositivo.
///
/// Las rutas que llegan del modelo son del **contenedor** (`/workspace/...`), así
/// que se traducen antes de tocar el disco. Se rechaza cualquier ruta que se
/// salga del workspace: el agente puede editar el proyecto, no el resto del
/// teléfono.
class WorkspaceFileSystemSeam implements FileSystemSeam {
  const WorkspaceFileSystemSeam({required this.hostWorkspace});

  final String hostWorkspace;

  String resolve(final String path) {
    final root = Directory(hostWorkspace).absolute.path;

    // La traducción se hace a mano, segmento a segmento, en lugar de confiar en
    // `p.join`: su tratamiento de las rutas absolutas como segundo argumento
    // cambia el resultado y aquí un fallo significa leer fuera del workspace.
    final String relative;
    if (path == '/workspace' || path.startsWith('/workspace/')) {
      relative = path.substring('/workspace'.length);
    } else if (path.startsWith('/')) {
      throw RuntimeException(
        'La ruta "$path" es absoluta y está fuera de /workspace. Usa rutas '
        'dentro de /workspace o relativas a él.',
      );
    } else {
      relative = path;
    }

    final segments = <String>[];
    for (final segment in relative.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) {
          throw RuntimeException(
            'La ruta "$path" intenta salir del workspace. Solo puedes trabajar '
            'dentro de /workspace.',
          );
        }
        segments.removeLast();
        continue;
      }
      segments.add(segment);
    }

    return <String>[root, ...segments].join(Platform.pathSeparator);
  }

  @override
  Future<String> readFile(final String path) =>
      File(resolve(path)).readAsString();

  @override
  Future<void> writeFile(final String path, final String content) async {
    final file = File(resolve(path));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  @override
  Future<bool> exists(final String path) async {
    final host = resolve(path);
    return File(host).existsSync() || Directory(host).existsSync();
  }

  @override
  Future<List<String>> list(final String path) async {
    final dir = Directory(resolve(path));
    final entries = await dir.list().toList();
    entries.sort((final a, final b) => a.path.compareTo(b.path));
    return entries
        .map((final e) => p.posix.join(path, p.basename(e.path)))
        .toList();
  }

  @override
  Future<List<String>> glob(final String pattern) async {
    // Glob mínimo sobre `*` y `**`: suficiente para que el modelo explore y no
    // arrastra una dependencia más al APK.
    final base = resolve('/workspace');
    final matcher = _globToRegExp(pattern);
    final results = <String>[];
    await for (final entity in Directory(base).list(recursive: true)) {
      if (entity is! File) continue;
      final relative = p.posix.join(
        '/workspace',
        p.split(p.relative(entity.path, from: base)).join('/'),
      );
      if (matcher.hasMatch(relative) ||
          matcher.hasMatch(p.posix.basename(relative))) {
        results.add(relative);
      }
      if (results.length >= 500) break;
    }
    return results;
  }

  @override
  Future<List<String>> grep(final String pattern, {final String? path}) async {
    final expression = RegExp(pattern);
    final root = Directory(resolve(path ?? '/workspace'));
    final matches = <String>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      if (!_isTextCandidate(entity.path)) continue;
      final lines = await entity.readAsLines();
      for (var i = 0; i < lines.length; i++) {
        if (expression.hasMatch(lines[i])) {
          final relative = p.posix.join(
            '/workspace',
            p.split(p.relative(entity.path, from: hostWorkspace)).join('/'),
          );
          matches.add('$relative:${i + 1}:${lines[i]}');
        }
        if (matches.length >= 500) return matches;
      }
    }
    return matches;
  }

  static bool _isTextCandidate(final String path) {
    const binary = <String>{
      '.so',
      '.apk',
      '.dex',
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.zip',
      '.gz',
      '.tar',
      '.pdf',
      '.ttf',
      '.otf',
      '.mp4',
      '.mp3',
    };
    return !binary.contains(p.extension(path).toLowerCase());
  }

  static RegExp _globToRegExp(final String pattern) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      if (char == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buffer.write('.*');
          i++;
        } else {
          buffer.write('[^/]*');
        }
      } else if (char == '?') {
        buffer.write('.');
      } else {
        buffer.write(RegExp.escape(char));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}
