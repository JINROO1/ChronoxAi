import 'dart:io';

/// Cómo se consigue un terminal **interactivo de verdad** dentro del contenedor.
///
/// El problema: la app no puede asignar un PTY desde Dart (`dart:io` no expone
/// `openpty`) ni desde Kotlin (`android.system.Os` no publica `ioctl`, y
/// `libandroid.so` no exporta la familia `openpty`, que vive en `libutil`). Sin
/// PTY, `isatty(stdin)` es falso dentro del invitado: no hay edición de línea,
/// ni historial, ni Ctrl+C, ni `nano`/`top`/`less` utilizables.
///
/// La solución: dejar que el propio contenedor abra el PTY con `script`, que
/// forma parte del Debian base (`bsdutils`, Prioridad esencial). `script` crea
/// un PTY, ejecuta el shell con él como entrada y salida, y reenvía lo que ese
/// shell escribe. Android ve tuberías normales; el invitado ve un terminal.
///
/// Consecuencias de esta decisión, escritas aquí para no redescubrirlas:
///
///  * El tamaño de ventana no se puede propagar sin `TIOCSWINSZ`, así que el
///    shell trabaja con 80 columnas y el emulador de pantalla **envuelve** las
///    líneas largas por su cuenta en lugar de esperar que lo haga el invitado.
///  * Las secuencias de escape llegan a Dart como bytes; la decodificación a
///    texto y el estado del cursor se manejan en la capa de pantalla.
///  * `script -e` hace que salga con el código del shell, no con el suyo.
abstract final class MenuScript {
  /// Shell por defecto dentro del invitado.
  static const String shellPorDefecto = '/bin/bash';

  /// Tipo de terminal que se anuncia. Es el que el emulador de pantalla sabe
  /// interpretar; dejarlo en `dumb` desactiva color y movimiento de cursor.
  static const String terminal = 'xterm-256color';

  /// Comando que se pasa a `script -c`.
  ///
  /// `exec` para no dejar un `sh` intermedio colgado entre `script` y el shell.
  static String comandoInterior({
    String shell = shellPorDefecto,
    String term = terminal,
  }) =>
      'TERM=$term exec $shell -l';

  /// Argumentos de `script` para un shell interactivo.
  ///
  /// * `-q`: sin el banner «Script started, file is typescript».
  /// * `-f`: vaciar la salida en cada escritura. Sin esto se acumula en búfer y
  ///   el usuario escribe a ciegas hasta que se llena.
  /// * `-e`: heredar el código de salida del shell.
  static List<String> argumentos({
    String shell = shellPorDefecto,
    String term = terminal,
  }) =>
      <String>[
        'script',
        '-q',
        '-f',
        '-e',
        '-c',
        comandoInterior(shell: shell, term: term),
      ];

  /// Comando completo que se pasa a proot: `sh -c "… exec script …"`.
  ///
  /// Pasa por `sh -c` porque el `TERM` tiene que llegar al `script` del
  /// invitado, no solo al proceso de Android. El `exec` final sustituye a `sh`,
  /// así que no queda un proceso de más entre proot y `script`.
  static List<String> envolturaInterior({
    String shell = shellPorDefecto,
    String term = terminal,
  }) =>
      <String>[
        '/bin/sh',
        '-c',
        'TERM=$term exec script -q -f -e -c "exec $shell -l"',
      ];

  /// Rutas donde puede estar `script` dentro del rootfs.
  ///
  /// `/bin` y `/usr/bin` son el mismo directorio en Debian por el usr-merge,
  /// pero se comprueban las dos porque el rootfs puede venir de una imagen
  /// anterior al merge.
  static List<String> rutasCandidatas(final String rootfs) => <String>[
        '$rootfs/usr/bin/script',
        '$rootfs/bin/script',
      ];

  /// `true` si el rootfs tiene `script`. Sin él no hay terminal interactiva, y
  /// es mejor saberlo antes de abrir una pantalla vacía.
  static bool disponible(final String rootfs) =>
      rutasCandidatas(rootfs).any((final ruta) =>
          FileSystemEntity.typeSync(ruta) != FileSystemEntityType.notFound);
}
