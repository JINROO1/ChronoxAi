import '../../platform/android_runtime_channel.dart';

/// Gravedad de un problema de compatibilidad.
///
/// Se distinguen tres niveles porque la respuesta del usuario es distinta en cada
/// uno: un bloqueante exige cambiar de dispositivo o de estrategia; un aviso
/// significa que algo puede fallar en ciertos casos; una nota solo explica por
/// qué la app se comporta de una manera que parece rara (el diálogo de "app
/// antigua" de Android, por ejemplo).
enum CompatSeverity { blocking, warning, note }

/// Un hallazgo concreto sobre este dispositivo.
class CompatIssue {
  const CompatIssue({
    required this.severity,
    required this.title,
    required this.detail,
    this.advice = '',
  });

  final CompatSeverity severity;
  final String title;
  final String detail;

  /// Qué puede hacer el usuario, si hay algo que hacer.
  final String advice;

  bool get isBlocking => severity == CompatSeverity.blocking;
}

/// Diagnóstico de compatibilidad del dispositivo con el runtime Linux.
///
/// Es lógica pura sobre [PlatformFacts]: se puede probar sin teléfono, que es la
/// única forma de cubrir la matriz de versiones de Android sin comprar veinte
/// dispositivos.
///
/// El caso que más importa aquí es Android 10+ con `targetSdk` alto: SELinux deja
/// de permitir `execve` sobre el almacenamiento privado y el contenedor no
/// arranca. Por eso se prefiere el dato **medido** (`canExecuteFromData`) a la
/// regla teórica, que las ROMs personalizadas incumplen de vez en cuando.
abstract final class RuntimeCompatibility {
  /// Versión mínima soportada (`minSdk` del proyecto).
  static const int minSdk = 24;

  /// Evalúa el dispositivo y devuelve los hallazgos ordenados por gravedad.
  static List<CompatIssue> evaluate(
    final PlatformFacts facts, {
    final bool? binariesAligned16K,
  }) {
    final issues = <CompatIssue>[];

    if (!facts.isAndroid) {
      return <CompatIssue>[
        const CompatIssue(
          severity: CompatSeverity.note,
          title: 'Ejecutando fuera de Android',
          detail: 'No se puede ejecutar el contenedor proot en este sistema.',
        ),
      ];
    }

    // --- Arquitectura -------------------------------------------------------
    if (!facts.isSupportedAbi) {
      issues.add(
        CompatIssue(
          severity: CompatSeverity.blocking,
          title: 'Procesador no soportado',
          detail:
              'El contenedor de Debian se empaqueta para ARM64 (y x86_64 en '
              'emulador). Este dispositivo informa "${facts.abi}".',
          advice:
              'Chronox necesita un dispositivo de 64 bits ARM. Un móvil de 32 '
              'bits no puede ejecutar este rootfs.',
        ),
      );
    }

    // --- Versión de Android -------------------------------------------------
    if (facts.sdkInt > 0 && facts.sdkInt < minSdk) {
      issues.add(
        CompatIssue(
          severity: CompatSeverity.blocking,
          title: 'Android demasiado antiguo',
          detail:
              'La app necesita Android ${_versionName(minSdk)} (API $minSdk) o '
              'superior; este dispositivo tiene API ${facts.sdkInt}.',
        ),
      );
    }

    // --- Permiso de ejecución (el punto crítico) ---------------------------
    if (facts.appDataExecBlocked) {
      final domain = facts.expectedDomain;
      issues.add(
        CompatIssue(
          severity: CompatSeverity.blocking,
          title: 'Android bloquea ejecutar programas de la app',
          detail: 'Desde Android 10, SELinux impide ejecutar ficheros del '
              'almacenamiento privado a las apps con targetSdk 29 o superior. '
              'Este dispositivo tiene API ${facts.sdkInt} '
              '(Android ${_versionName(facts.sdkInt)}), el proceso corre en el '
              'dominio "$domain" y la app declara targetSdk ${facts.targetSdk}.',
          advice:
              'Si el dominio no es untrusted_app_27, puede que otra app con el '
              'mismo uid haya forzado el dominio, o que una instalación anterior '
              'lo haya dejado pegado. Desinstala la app por completo (no basta '
              'con reinstalar) y vuelve a instalarla.',
        ),
      );
    }

    // --- Páginas de 16 KB ---------------------------------------------------
    if (facts.has16KPages) {
      final aligned = binariesAligned16K;
      if (aligned == false) {
        issues.add(
          const CompatIssue(
            severity: CompatSeverity.blocking,
            title: 'Binarios no compatibles con páginas de 16 KB',
            detail: 'Este dispositivo usa páginas de memoria de 16 KB (Android '
                '15+). Los binarios empaquetados están alineados solo a 4 KB y '
                'el kernel no puede cargarlos.',
            advice: 'Hay que recompilar o actualizar proot con '
                '-Wl,-z,max-page-size=16384.',
          ),
        );
      } else if (aligned == null) {
        issues.add(
          const CompatIssue(
            severity: CompatSeverity.warning,
            title: 'Páginas de memoria de 16 KB',
            detail: 'Este dispositivo usa páginas de 16 KB. Los binarios se '
                'verifican al instalarse; si alguno no está alineado, el '
                'contenedor no arrancará.',
          ),
        );
      }
    }

    // --- targetSdk bajo -----------------------------------------------------
    if (facts.sdkInt >= 35 && facts.targetSdk <= 28) {
      issues.add(
        const CompatIssue(
          severity: CompatSeverity.note,
          title: 'Aviso de "app creada para una versión anterior"',
          detail: 'Android 15 muestra este aviso para apps con targetSdk 28 o '
              'menor. Es intencionado: ese targetSdk es justo lo que mantiene '
              'el permiso para ejecutar proot.',
          advice:
              'Es normal. La app no tiene acceso a menos funciones por ello.',
        ),
      );
    }

    if (facts.sdkInt >= 33 && facts.sdkInt < 35) {
      issues.add(
        const CompatIssue(
          severity: CompatSeverity.note,
          title: 'Permiso de notificaciones',
          detail: 'Android 13+ pide permiso para mostrar notificaciones. El '
              'servicio que mantiene vivos los comandos en segundo plano lo '
              'necesita para ser visible.',
        ),
      );
    }

    // --- Fabricantes con gestión agresiva de batería ------------------------
    final vendor = facts.manufacturer.toLowerCase();
    final aggressive = <String, String>{
      'xiaomi': 'MIUI/HyperOS',
      'redmi': 'MIUI/HyperOS',
      'nubia': 'RedMagic OS',
      'zte': 'RedMagic OS',
      'oppo': 'ColorOS',
      'realme': 'realme UI',
      'vivo': 'OriginOS/Funtouch',
      'oneplus': 'OxygenOS',
      'samsung': 'One UI',
      'huawei': 'EMUI/HarmonyOS',
      'honor': 'MagicOS',
    };
    final rom = aggressive[vendor];
    if (rom != null) {
      issues.add(
        CompatIssue(
          severity: CompatSeverity.warning,
          title: 'Segundo plano: $rom cierra apps',
          detail:
              '$rom mata procesos en segundo plano de forma agresiva. Un '
              '"apt install" largo o el agente trabajando con la pantalla '
              'apagada puede detenerse a mitad.',
          advice:
              'Desactiva la optimización de batería para Chronox AI en Ajustes '
              '→ Batería, y bloquéala en la lista de apps recientes '
              '($rom → Ajustes de la app → "Sin restricciones").',
        ),
      );
    }

    issues.sort(
      (final a, final b) => a.severity.index.compareTo(b.severity.index),
    );
    return issues;
  }

  /// `true` si el dispositivo puede ejecutar el contenedor.
  static bool canRun(
    final PlatformFacts facts, {
    final bool? binariesAligned16K,
  }) =>
      !evaluate(facts, binariesAligned16K: binariesAligned16K)
          .any((final issue) => issue.isBlocking);

  /// Nombre comercial de una versión de Android, para mensajes legibles.
  static String _versionName(final int sdk) => switch (sdk) {
        <= 0 => 'desconocida',
        < 24 => 'antiguo',
        24 || 25 => '7.x',
        26 || 27 => '8.x',
        28 => '9',
        29 => '10',
        30 => '11',
        31 || 32 => '12',
        33 => '13',
        34 => '14',
        35 => '15',
        36 => '16',
        _ => 'API $sdk',
      };

  /// Resumen corto para la pantalla de diagnóstico: "Android 15 · arm64 ·
  /// 16 KB · exec OK".
  static String summary(final PlatformFacts facts) {
    final parts = <String>[
      'Android ${_versionName(facts.sdkInt)}',
      facts.abi,
      if (facts.has16KPages) 'páginas 16 KB' else 'páginas 4 KB',
      if (facts.appDataExecBlocked) 'exec bloqueado' else 'exec OK',
    ];
    return parts.join(' · ');
  }
}
