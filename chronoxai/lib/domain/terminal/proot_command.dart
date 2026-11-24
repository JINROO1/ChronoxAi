import 'dart:io';

/// Parámetros con los que se construye la línea de comandos de `proot`.
///
/// Todos los caminos de `host` son absolutos **en el dispositivo Android**; todos
/// los de `guest` son absolutos **dentro** del contenedor.
class ProotConfig {
  const ProotConfig({
    required this.prootBinary,
    required this.prootLoader,
    required this.rootfs,
    required this.workingDirectory,
    this.homeDirectory = '/root',
    this.bindMounts = const <BindMount>[],
    this.environment = const <String, String>{},
    this.fakeKernelRelease,
    this.hostname = 'chronoxai',
    this.uid = 0,
    this.gid = 0,
    this.link2symlink = true,
    this.sysvipc = true,
    this.killOnExit = true,
    this.portRedirects = const <int, int>{},
  });

  /// Ruta al `proot` ejecutable (en Android: `nativeLibraryDir/libproot.so`).
  final String prootBinary;

  /// Ruta al loader nativo de PRoot dentro de `nativeLibraryDir`.
  /// Se publica al hijo como `PROOT_LOADER` (no como PROOT_UNBUNDLE_LOADER, que
  /// es una ruta de instalación fijada en tiempo de compilación de PRoot).
  final String prootLoader;

  /// Rootfs de la distro (p. ej. `filesDir/linux/debian`).
  final String rootfs;

  /// Directorio de trabajo dentro del invitado (p. ej. `/workspace`).
  final String workingDirectory;

  final String homeDirectory;
  final List<BindMount> bindMounts;

  /// Variables de entorno **dentro** del contenedor.
  final Map<String, String> environment;

  /// Cadena de `uname -r` falsa. `apt` y muchos `configure` la leen.
  final String? fakeKernelRelease;

  final String hostname;
  final int uid;
  final int gid;

  /// Emula hardlinks con symlinks. **Necesario** para que `apt`/`dpkg` funcionen.
  final bool link2symlink;

  /// Emula System V IPC (PostgreSQL y otros lo requieren).
  final bool sysvipc;

  /// Mata los procesos hijos al terminar proot; evita zombis.
  final bool killOnExit;

  /// Redirección de puertos privilegiados: invitado → host (`{22: 2022}`).
  final Map<int, int> portRedirects;
}

/// Un montaje vinculado: ruta del dispositivo → ruta dentro del contenedor.
class BindMount {
  const BindMount(this.hostPath, this.guestPath, {this.readOnly = false});

  final String hostPath;
  final String guestPath;
  final bool readOnly;

  String get specification =>
      readOnly ? '$hostPath:$guestPath:ro' : '$hostPath:$guestPath';
}

/// Construye el argv de `proot` en el **orden canónico** que usa `proot-distro`.
///
/// El orden importa: proot procesa las opciones de izquierda a derecha y algunas
/// de ellas (como `--rootfs`) cambian cómo se resuelven las posteriores.
abstract final class ProotCommandBuilder {
  /// Versión de kernel falsa por defecto.
  ///
  /// Debian exige un `uname -r` plausible; si se deja el de Android (`4.14.x`),
  /// algunos paquetes detectan "Android" y fallan, y `apt` se queja del formato.
  static const String defaultKernelRelease = '6.1.0-chronox';

  /// Construye el argv completo, sin incluir el binario.
  ///
  /// [inner] es el comando a ejecutar dentro del contenedor; si se omite, se usa
  /// un shell de login interactivo.
  static List<String> build(
    final ProotConfig config, {
    List<String>? inner,
    String shell = '/bin/bash',
  }) {
    final args = <String>[];

    // 1. Extensiones de proot (orden tomado de proot-distro).
    if (config.killOnExit) {
      args.add('--kill-on-exit');
    }
    if (config.link2symlink) {
      args.add('--link2symlink');
    }
    if (config.sysvipc) {
      args.add('--sysvipc');
    }

    // 2. Kernel falso. `apt`, `dpkg` y muchos `./configure` leen `uname -r`;
    //    si ven un kernel de Android se niegan a continuar o detectan mal el SO.
    if (config.fakeKernelRelease != null) {
      args.add('--kernel-release=${config.fakeKernelRelease}');
    }

    // 3. `-L`: corrige `lstat` para que dpkg no avise de symlinks falsos.
    args.add('-L');

    // 5. Identidad falsa. Dentro de proot siempre somos "root" sin privilegios
    //    reales; sirve para que apt no se queje.
    args.add('--change-id=${config.uid}:${config.gid}');

    // 5. Raíz y directorio de trabajo.
    args.add('--rootfs=${config.rootfs}');
    args.add('--cwd=${config.workingDirectory}');

    // 6. Montajes base. Sin /dev, /proc y /sys dentro del contenedor, bash no
    //    arranca y apt falla de formas confusas.
    args.add('--bind=/dev');
    args.add('--bind=/proc');
    args.add('--bind=/sys');

    // 7. Montajes del usuario (workspace, caché, etc.).
    for (final mount in config.bindMounts) {
      args.add('--bind=${mount.specification}');
    }

    // 8. HOME. Si el llamador ya monta algo sobre el HOME del invitado (lo normal:
    //    un directorio persistente fuera del rootfs), no se añade otro bind aquí;
    //    dos montajes sobre la misma ruta dejan el resultado a merced del orden.
    final homeAlreadyMounted =
        config.bindMounts.any((final m) => m.guestPath == config.homeDirectory);
    if (!homeAlreadyMounted) {
      args.add(
        '--bind=${config.rootfs}${config.homeDirectory}:${config.homeDirectory}',
      );
    }

    // 9. Redirección de puertos privilegiados.
    if (config.portRedirects.isNotEmpty) {
      args.add('-p');
      // La sintaxis de -p es una lista separada por comas de "guest:host".
      args.add(
        config.portRedirects.entries
            .map((final e) => '${e.key}:${e.value}')
            .join(','),
      );
    }

    // 10. Comando interior.
    final command = inner ?? <String>[shell, '-l'];
    args.addAll(command);

    return args;
  }

  /// Variables de entorno del **proceso proot** en el dispositivo (no del invitado).
  ///
  /// `LD_LIBRARY_PATH` apunta a los JNI extraídos y al directorio temporal,
  /// donde LocalRuntime crea el alias `libtalloc.so.2` que proot necesita.
  static Map<String, String> hostEnvironment({
    required final String nativeLibraryDir,
    required final String tempDir,
    required final String prootLoader,
    final Map<String, String> extra = const <String, String>{},
  }) {
    return <String, String>{
      // Dependencias dinámicas de proot.
      'LD_LIBRARY_PATH': <String>[
        nativeLibraryDir,
        tempDir,
      ].join(':'),
      // El PRoot de Termux usa PROOT_UNBUNDLE_LOADER como directorio en tiempo
      // de compilación; PROOT_LOADER lo sobreescribe con el loader APK ejecutable.
      'PROOT_LOADER': prootLoader,
      // Archivos temporales de PRoot siempre fuera de nativeLibraryDir.
      'PROOT_TMP_DIR': tempDir,
      // Seccomp puede interferir con ptrace en algunos kernels de Android.
      'PROOT_NO_SECCOMP': '1',
      // Evita fallos de glibc rseq en invitados modernos bajo ptrace.
      'GLIBC_TUNABLES': 'glibc.pthread.rseq=0',
      // Termux exporta estos en el invitado; algunos paquetes los esperan.
      'TERM': 'xterm-256color',
      'LANG': 'C.UTF-8',
      ...extra,
    };
  }

  /// Fragmento de `--kernel-release` con el formato que exige proot.
  ///
  /// proot espera una sola cadena con los seis campos separados por `\`.
  static String kernelRelease({
    final String hostname = 'chronoxai',
    final String release = defaultKernelRelease,
    final String machine = 'aarch64',
  }) {
    return '\\Linux\\$hostname\\$release\\$machine\\localdomain\\-1\\';
  }

  /// Variables de entorno **dentro** del contenedor, ya con HOME y PATH.
  static Map<String, String> guestEnvironment(final ProotConfig config) {
    return <String, String>{
      'HOME': config.homeDirectory,
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'TERM': 'xterm-256color',
      'LANG': 'C.UTF-8',
      'HOSTNAME': config.hostname,
      ...config.environment,
    };
  }

  /// Valida la configuración y devuelve problemas legibles por humanos.
  static List<String> validate(final ProotConfig config) {
    final problems = <String>[];
    if (config.prootBinary.trim().isEmpty) {
      problems.add('Falta la ruta al binario de proot.');
    }
    if (config.prootLoader.trim().isEmpty) {
      problems
          .add('Falta la ruta al loader ejecutable de proot (PROOT_LOADER).');
    }
    if (!config.rootfs.startsWith('/')) {
      problems.add('El rootfs debe ser una ruta absoluta: "${config.rootfs}".');
    }
    if (!config.workingDirectory.startsWith('/')) {
      problems.add(
        'El directorio de trabajo debe ser absoluto: "${config.workingDirectory}".',
      );
    }
    for (final mount in config.bindMounts) {
      if (!mount.hostPath.startsWith('/')) {
        problems.add('El montaje "${mount.hostPath}" no es una ruta absoluta.');
      }
    }
    return problems;
  }

  /// Comprueba que el binario existe y tiene permiso de ejecución.
  ///
  /// No se puede usar `File.statSync().mode` como única comprobación en Android,
  /// pero un fichero sin bits de ejecución es un fallo seguro y rápido de detectar.
  static Future<String?> checkBinary(final String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return 'No existe el binario: $path';
    }
    final stat = await file.stat();
    if (stat.size == 0) {
      return 'El binario está vacío: $path';
    }
    if (stat.mode & 0x49 == 0) {
      // 0o111
      return 'El binario no tiene permiso de ejecución: $path '
          '(chmod 0755)';
    }
    return null;
  }
}
