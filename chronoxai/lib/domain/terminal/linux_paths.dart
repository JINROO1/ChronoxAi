import 'dart:io';

import 'package:path/path.dart' as p;

/// Layout de directorios del runtime Linux dentro del almacenamiento privado.
///
/// Todo vive bajo `getFilesDir()` de la app (`/data/data/app.chronoxai/files`),
/// que es la única ubicación escribible sin permisos y, con `targetSdk 28`,
/// también ejecutable.
///
/// ```
/// files/
/// ├── linux/
/// │   ├── runtime/           loader de proot y temporales escribibles
/// │   ├── rootfs/<distro>/   árbol de Debian
/// │   ├── home/              HOME compartido entre distros
/// │   └── workspace/         proyecto que edita el agente (bind a /workspace)
/// ├── tmp/
/// └── sessions/              estado de sesiones del agente
/// ```
class LinuxPaths {
  const LinuxPaths({
    required this.filesDir,
    required this.distroId,
  });

  /// Directorio raíz privado de la app (`getFilesDir()`).
  final String filesDir;

  /// Identificador de la distro activa, p. ej. `debian-bookworm`.
  final String distroId;

  String get linuxRoot => p.join(filesDir, 'linux');

  /// Ficheros escribibles que proot necesita (su loader, `tmp`, etc.).
  String get runtimeDir => p.join(linuxRoot, 'runtime');

  /// Raíz del sistema de archivos de la distro.
  String get rootfsDir => p.join(linuxRoot, 'rootfs', distroId);

  /// HOME del invitado, compartido para que `~/.bashrc` sobreviva a reinstalar.
  String get homeDir => p.join(linuxRoot, 'home');

  /// Carpeta de proyecto visible dentro del contenedor como `/workspace`.
  String get workspaceDir => p.join(linuxRoot, 'workspace');

  /// Temporales del proceso proot en el dispositivo.
  String get tempDir => p.join(filesDir, 'tmp');

  /// Estado persistente del agente (historial, PIDs de sesiones).
  String get sessionsDir => p.join(filesDir, 'sessions');

  /// Ruta donde proot desempaqueta su loader.
  String get prootLoaderPath => p.join(runtimeDir, 'proot-loader');

  /// Crea todos los directorios necesarios. Idempotente.
  Future<void> ensure() async {
    for (final dir in <String>[
      linuxRoot,
      runtimeDir,
      rootfsDir,
      homeDir,
      workspaceDir,
      tempDir,
      sessionsDir,
    ]) {
      await Directory(dir).create(recursive: true);
    }
  }

  /// `true` si el rootfs parece instalado (tiene un `/bin/sh` utilizable).
  bool get looksInstalled {
    final markers = <String>[
      p.join(rootfsDir, 'bin', 'bash'),
      p.join(rootfsDir, 'bin', 'sh'),
      p.join(rootfsDir, 'usr', 'bin', 'bash'),
    ];
    return markers
        .any((final m) => File(m).existsSync() || Link(m).existsSync());
  }

  /// Variable `HOME` dentro del contenedor (no la del dispositivo).
  String get guestHome => '/root';

  /// Montajes estándar que se pasan a proot.
  List<({String host, String guest, bool readOnly})> get standardBinds {
    return <({String host, String guest, bool readOnly})>[
      (host: workspaceDir, guest: '/workspace', readOnly: false),
      (host: homeDir, guest: '/root', readOnly: false),
    ];
  }
}
