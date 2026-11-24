import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

import '../../domain/plugins/seams.dart';
import '../../domain/plugins/sandbox_policy.dart';
import '../../domain/plugins/mcp_npm_spec.dart';
import '../../domain/plugins/npm_lockfile_policy.dart';
import '../../domain/terminal/linux_paths.dart';
import '../../domain/terminal/elf_inspector.dart';
import '../../domain/terminal/proot_command.dart';
import '../../domain/terminal/runtime_compat.dart';
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

  /// Los binarios del APK no pueden cargarse con el tamaño de página del kernel.
  pageSizeMismatch,
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
        RuntimeProblem.pageSizeMismatch => 'Binarios incompatibles con Android',
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
          'El APK no incluye libproot o su loader nativo. La build debe contener '
              'libproot.so y libproot_loader.so en jniLibs para cada ABI.',
        RuntimeProblem.missingRootfs =>
          'Todavía no hay un sistema Linux instalado. Descarga Debian para poder '
              'ejecutar comandos.',
        RuntimeProblem.unavailable =>
          detail.isEmpty ? 'El runtime no está disponible.' : detail,
        RuntimeProblem.pageSizeMismatch => detail.isEmpty
            ? 'Los binarios de proot no están alineados al tamaño de página de '
                'este dispositivo (16 KB) y no se pueden cargar.'
            : detail,
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
  bool _prootSmokeValidated = false;

  /// Ruta del workspace tal y como se ve **dentro** del contenedor.
  static const String guestWorkspace = '/workspace';

  /// Ruta del workspace en el dispositivo.
  String get hostWorkspace => paths.workspaceDir;

  Future<PlatformFacts> facts() async => _facts ??= await _channel.read();

  /// Últimos hallazgos de compatibilidad, para la pantalla de diagnóstico.
  List<CompatIssue> compatIssues = const <CompatIssue>[];

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
    if (!File(proot).existsSync()) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingBinaries,
        detail: 'No se encontró el ejecutable de proot empaquetado: $proot.',
      );
    }
    _prootPath = proot;

    final loader = p.join(nativeLibraryDir, 'libproot_loader.so');
    if (!File(loader).existsSync()) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingBinaries,
        detail:
            'No se encontró el loader nativo de PRoot empaquetado: $loader.',
      );
    }
    _loaderPath = loader;

    // Android empaqueta/extráe los JNI con nombre `*.so`, así que el alias
    // libtalloc.so.2 no viaja en el APK. Proot lo pide por SONAME; crea ese
    // alias en el tmp privado de la app y añádelo al linker path del proceso.
    try {
      final talloc = File(p.join(nativeLibraryDir, 'libtalloc.so'));
      if (!await talloc.exists()) {
        throw FileSystemException('No se empaquetó libtalloc.so', talloc.path);
      }
      await Directory(paths.tempDir).create(recursive: true);
      final sonameAlias = File(p.join(paths.tempDir, 'libtalloc.so.2'));
      if (!await sonameAlias.exists() ||
          await sonameAlias.length() != await talloc.length()) {
        await talloc.copy(sonameAlias.path);
      }
    } on FileSystemException catch (error) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingBinaries,
        detail: 'No se pudo preparar la dependencia nativa de proot: $error',
      );
    }

    // El diagnóstico completo se calcula siempre, incluso con el rootfs ya
    // instalado: los avisos (batería, páginas de 16 KB, aviso de app antigua)
    // siguen siendo útiles para el usuario.
    //
    // Solo se inspeccionan los ELF si el kernel usa 16 KB: con páginas de 4 KB la
    // alineación es indiferente y nos ahorramos leer el fichero.
    final aligned = facts.has16KPages ? await verifyBinaries() : null;
    compatIssues = RuntimeCompatibility.evaluate(
      facts,
      binariesAligned16K: aligned,
      guestExecViaProotLoader: _loaderPath != null,
    );
    final blocking = compatIssues.where((final i) => i.isBlocking).toList();

    if (blocking.isNotEmpty) {
      final issue = blocking.first;
      final problem = switch (issue.title) {
        final t when t.contains('16 KB') => RuntimeProblem.pageSizeMismatch,
        final t when t.contains('Procesador') =>
          RuntimeProblem.unsupportedDevice,
        _ => RuntimeProblem.execBlocked,
      };
      return RuntimeStatus(
        isReady: false,
        problem: problem,
        detail: issue.advice.isEmpty
            ? issue.detail
            : '${issue.detail} ${issue.advice}',
      );
    }

    // El rootfs existe si tiene un `/bin/sh` real. Comprobar solo el directorio
    // daría falsos positivos con una descarga a medias.
    final guestShell = File(p.join(paths.rootfsDir, 'bin', 'sh'));
    if (guestShell.existsSync() && facts.isAndroid) {
      // Reparar en cada comprobación: distintas entradas de shell pueden ser
      // copias/enlaces distintos (/bin/sh y /usr/bin/sh), y una versión previa
      // del rootfs pudo dejar ejecutable uno pero no el otro.
      final repaired =
          await _channel.repairRootfsExecutableBits(paths.rootfsDir);
      if (!repaired) {
        return RuntimeStatus(
          isReady: false,
          problem: RuntimeProblem.unavailable,
          detail: 'El rootfs existe, pero Android no pudo reparar los permisos '
              'de ejecución de sus comandos. Reinstala Debian desde Ajustes.',
        );
      }
      final repairedStat = await guestShell.stat();
      if ((repairedStat.mode & 0x49) == 0) {
        return RuntimeStatus(
          isReady: false,
          problem: RuntimeProblem.unavailable,
          detail:
              'No se pudo marcar /bin/sh como ejecutable. Reinstala Debian.',
        );
      }
    }
    if (!guestShell.existsSync()) {
      return RuntimeStatus(
        isReady: false,
        problem: RuntimeProblem.missingRootfs,
        detail: 'Se esperaba ${guestShell.path}.',
      );
    }

    // No basta con que los ELF estén en el APK: el primer chequeo del rootfs
    // arranca PRoot de verdad y ejecuta un comando invitado. Así se detectan
    // errores de PROOT_LOADER/ptrace/ABI antes de abrir una terminal vacía.
    if (!_prootSmokeValidated) {
      try {
        final smoke = await run(
          "printf '%s' 'CHRONOX_PROOT_OK'",
          timeout: const Duration(seconds: 20),
        );
        if (!smoke.isSuccess || !smoke.stdout.contains('CHRONOX_PROOT_OK')) {
          return RuntimeStatus(
            isReady: false,
            problem: RuntimeProblem.unavailable,
            detail: 'PRoot no pudo ejecutar el smoke test del rootfs '
                '(exit ${smoke.exitCode}). '
                '${smoke.stderr.isEmpty ? smoke.stdout : smoke.stderr}',
          );
        }
        _prootSmokeValidated = true;
      } on Object catch (error) {
        return RuntimeStatus(
          isReady: false,
          problem: RuntimeProblem.unavailable,
          detail: 'No se pudo iniciar PRoot desde nativeLibraryDir: $error',
        );
      }
    }

    return RuntimeStatus(isReady: true, prootPath: proot);
  }

  /// Verifica los ELF empaquetados contra el tamaño de página del kernel.
  ///
  /// Devuelve `null` si no se pudieron inspeccionar (no es un fallo: solo impide
  /// afirmar nada).
  Future<bool?> verifyBinaries() async {
    final binaries = <String?>[_prootPath, _loaderPath];
    if (binaries.any((final path) => path == null)) return null;
    try {
      for (final path in binaries.cast<String>()) {
        final info = await ElfInspector.inspectFile(path);
        if (!info.supports16KPages) return false;
      }
      return true;
    } catch (_) {
      return null;
    }
  }

  /// Inicia un proceso persistente de plugin dentro del rootfs.
  /// Solo se permite ejecutar scripts bajo `/workspace/.chronox/plugins/`.
  Future<Process> startPluginProcess(final String guestScript) async {
    final normalized = p.posix.normalize(guestScript);
    if (!normalized.startsWith('/workspace/.chronox/plugins/') ||
        normalized.contains('/../')) {
      throw ArgumentError.value(
        guestScript,
        'guestScript',
        'Ruta de plugin no permitida.',
      );
    }
    final current = await status();
    if (!current.isReady) {
      throw StateError('No se puede iniciar un plugin: ${current.title}.');
    }
    final config = await _config(workingDirectory: '/workspace');
    final args = ProotCommandBuilder.build(
      config,
      inner: <String>[
        '/bin/bash',
        '-lc',
        'python3 -u ${_shellQuote(normalized)}',
      ],
    );
    final environment = ProotCommandBuilder.hostEnvironment(
      nativeLibraryDir: p.dirname(config.prootBinary),
      tempDir: paths.tempDir,
      prootLoader: config.prootLoader,
    );
    await Directory(paths.tempDir).create(recursive: true);
    return Process.start(
      config.prootBinary,
      args,
      environment: environment,
      workingDirectory: paths.filesDir,
    );
  }

  /// Inicia un servidor MCP de stdio dentro de Debian. Solo se admite un
  /// lanzador conocido (node/npm/npx); los argumentos se citan individualmente.
  Future<Process> startMcpProcess(
    final List<String> command,
    final Map<String, String> serverEnvironment,
  ) async {
    if (command.isEmpty ||
        command.any((final part) => part.contains('\u0000'))) {
      throw ArgumentError.value(command, 'command', 'Comando MCP inválido.');
    }
    final current = await status();
    if (!current.isReady) {
      throw StateError('Runtime no listo: ${current.title}.');
    }

    late final List<String> launchCommand;
    if (command.first == 'npm-package') {
      final pinned = PinnedMcpPackage.parse(command);
      final npmCheck = await run('command -v npm');
      if (!npmCheck.isSuccess) {
        throw StateError(
            'Instala nodejs y npm en Debian para usar paquetes MCP.');
      }
      final packageId =
          sha256.convert(utf8.encode(pinned.spec)).toString().substring(0, 20);
      final hostDir = Directory(
          p.join(hostWorkspace, '.chronox', 'mcp-packages', packageId));
      await hostDir.create(recursive: true);
      final packageJson = File(p.join(hostDir.path, 'package.json'));
      final lockFile = File(p.join(hostDir.path, 'package-lock.json'));
      final expectedJson =
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'name': 'chronox-mcp-$packageId',
        'version': '1.0.0',
        'private': true,
        'dependencies': <String, String>{pinned.package: pinned.version},
      });
      if (await packageJson.exists() &&
          (jsonDecode(await packageJson.readAsString()) as Map)['dependencies']
                  [pinned.package] !=
              pinned.version) {
        throw StateError('package.json local no coincide con el pin MCP.');
      }
      await packageJson.writeAsString(expectedJson, flush: true);
      final installPrefix = '/workspace/.chronox/mcp-packages/$packageId';
      if (!await lockFile.exists()) {
        final lockResult = await run(
          'ulimit -f 131072; ulimit -n 128; ulimit -t 600; '
          'npm install --prefix ${_shellQuote(installPrefix)} '
          '--package-lock-only --ignore-scripts --save-exact --no-audit --no-fund',
          timeout: const Duration(minutes: 10),
        );
        if (!lockResult.isSuccess || !await lockFile.exists()) {
          throw StateError(
              'No se pudo generar package-lock.json: ${lockResult.stderr}');
        }
      }
      NpmLockfilePolicy.validateJson(
        await lockFile.readAsString(),
        expectedPackage: pinned.package,
        expectedVersion: pinned.version,
      );
      final ciResult = await run(
        'ulimit -f 131072; ulimit -n 128; ulimit -t 600; '
        'npm ci --prefix ${_shellQuote(installPrefix)} '
        '--ignore-scripts --no-audit --no-fund',
        timeout: const Duration(minutes: 10),
      );
      if (!ciResult.isSuccess) {
        throw StateError('npm ci falló: ${ciResult.stderr}');
      }
      launchCommand = <String>[
        p.join(installPrefix, 'node_modules', '.bin', pinned.binary),
      ];
    } else {
      if (!const <String>{'node', 'nodejs', 'npm', 'npx'}
          .contains(command.first)) {
        throw ArgumentError.value(
            command, 'command', 'Usa node, npm, npx o npm-package fijado.');
      }
      final executableCheck = await run('command -v ${command.first}');
      if (!executableCheck.isSuccess) {
        throw StateError(
            'Falta ${command.first} en Debian. Instala nodejs y npm antes de conectar servidores MCP npm.');
      }
      launchCommand = command;
    }
    final invalidEnvironment = serverEnvironment.entries.any((final entry) =>
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(entry.key) ||
        entry.value.contains('\u0000'));
    if (invalidEnvironment) {
      throw ArgumentError.value(serverEnvironment, 'environment',
          'Nombre de variable o valor inválido.');
    }
    final config = await _config(workingDirectory: '/workspace');
    // Bound CPU time, individual file growth and open descriptors for the MCP
    // process tree. npm dependency installation has a separate 10-minute wall
    // clock timeout above.
    final guestCommand = 'ulimit -t 1800; ulimit -f 131072; ulimit -n 128; '
        'exec ${launchCommand.map(_shellQuote).join(' ')}';
    final args = ProotCommandBuilder.build(config,
        inner: <String>['/bin/bash', '-lc', guestCommand]);
    final environment = ProotCommandBuilder.hostEnvironment(
      nativeLibraryDir: p.dirname(config.prootBinary),
      tempDir: paths.tempDir,
      prootLoader: config.prootLoader,
    );
    await Directory(paths.tempDir).create(recursive: true);
    return Process.start(
      config.prootBinary,
      args,
      environment: <String, String>{...environment, ...serverEnvironment},
      workingDirectory: paths.filesDir,
    );
  }

  /// Resolves an exact-pinned package into a reviewed lockfile without running
  /// package lifecycle scripts or installing node_modules.
  Future<String> preparePinnedMcpPackage(List<String> command) async {
    final pinned = PinnedMcpPackage.parse(command);
    final current = await status();
    if (!current.isReady)
      throw StateError('Runtime no listo: ${current.title}.');
    if (!(await run('command -v npm')).isSuccess) {
      throw StateError(
          'Instala nodejs y npm en Debian para usar paquetes MCP.');
    }
    final packageId =
        sha256.convert(utf8.encode(pinned.spec)).toString().substring(0, 20);
    final hostDir = Directory(
      p.join(hostWorkspace, '.chronox', 'mcp-packages', packageId),
    );
    await hostDir.create(recursive: true);
    final packageJson = File(p.join(hostDir.path, 'package.json'));
    final lockFile = File(p.join(hostDir.path, 'package-lock.json'));
    final expectedJson = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'name': 'chronox-mcp-$packageId',
        'version': '1.0.0',
        'private': true,
        'dependencies': <String, String>{pinned.package: pinned.version},
      },
    );
    if (await packageJson.exists()) {
      final existing = jsonDecode(await packageJson.readAsString());
      final dependencies = existing is Map ? existing['dependencies'] : null;
      if (dependencies is! Map ||
          dependencies[pinned.package] != pinned.version) {
        throw StateError('package.json local no coincide con el pin MCP.');
      }
    }
    await packageJson.writeAsString(expectedJson, flush: true);
    if (!await lockFile.exists()) {
      final prefix = '/workspace/.chronox/mcp-packages/$packageId';
      final result = await run(
        'ulimit -f 131072; ulimit -n 128; ulimit -t 600; '
        'npm install --prefix ${_shellQuote(prefix)} '
        '--package-lock-only --ignore-scripts --save-exact --no-audit --no-fund',
        timeout: const Duration(minutes: 10),
      );
      if (!result.isSuccess || !await lockFile.exists()) {
        throw StateError(
            'No se pudo generar package-lock.json: ${result.stderr}');
      }
    }
    final lockText = await lockFile.readAsString();
    NpmLockfilePolicy.validateJson(
      lockText,
      expectedPackage: pinned.package,
      expectedVersion: pinned.version,
    );
    return lockText;
  }

  static String _shellQuote(final String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

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
    final prootPath = _prootPath ?? p.join(nativeLibraryDir, 'libproot.so');
    final loaderPath =
        _loaderPath ?? p.join(nativeLibraryDir, 'libproot_loader.so');
    if (!await File(prootPath).exists() || !await File(loaderPath).exists()) {
      throw const RuntimeException(
        'Faltan libproot.so o libproot_loader.so en nativeLibraryDir.',
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
      prootBinary: prootPath,
      prootLoader: loaderPath,
      rootfs: paths.rootfsDir,
      workingDirectory: workingDirectory ?? guestWorkspace,
      homeDirectory: '/root',
      bindMounts: binds,
      fakeKernelRelease: ProotCommandBuilder.defaultKernelRelease,
    );
  }

  /// Comando completo para abrir una terminal interactiva (PTY).
  Future<void> _ensureTerminalBashrc() async {
    final bashrc = File(p.join(paths.homeDir, '.bashrc'));
    const defaults = '''
# ChronoxAI terminal defaults
if [ -r /etc/bash.bashrc ]; then . /etc/bash.bashrc; fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
PS1='\\W\\$ '
''';
    await bashrc.parent.create(recursive: true);
    if (!await bashrc.exists()) {
      await bashrc.writeAsString(defaults.trimLeft());
      return;
    }
    final contents = await bashrc.readAsString();
    if (!contents.contains('# ChronoxAI terminal defaults')) {
      await bashrc.writeAsString('$contents\n$defaults', flush: true);
    }
  }

  Future<({String binary, List<String> args, Map<String, String> env})>
      interactiveCommand({final String? workingDirectory}) async {
    final config = await _config(workingDirectory: workingDirectory);
    await _ensureTerminalBashrc();
    return (
      binary: config.prootBinary,
      args: ProotCommandBuilder.build(
        config,
        inner: ProotCommandBuilder.interactiveShell(config),
      ),
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
  const ProotShellSeam(this.runtime, {this.policy = const SandboxPolicy()});

  final LocalRuntime runtime;
  final SandboxPolicy policy;

  @override
  Future<ShellResult> run(
    final String command, {
    final String? workingDirectory,
    final Duration? timeout,
  }) {
    final violation = policy.violation(command);
    if (violation != null) {
      return Future<ShellResult>.value(ShellResult(
        exitCode: 126,
        stdout: '',
        stderr: 'Comando bloqueado por SandboxPolicy: $violation.',
      ));
    }
    return runtime.run(command,
        workingDirectory: workingDirectory, timeout: timeout);
  }
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
  }) async =>
      ShellResult(
        exitCode: 127,
        stdout: '',
        stderr: '${status.title}: no se pueden ejecutar comandos todavía.\n'
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
