import 'dart:io';

import 'package:path/path.dart' as p;

/// Ficheros de instrucciones del proyecto, al estilo de `AGENTS.md`.
///
/// DeepSeek Harness (y Claude Code, Codex…) leen estos ficheros de la raíz del
/// workspace y los inyectan en el system prompt: son la forma en que un
/// proyecto le dice al agente cómo trabajar en él (comandos de build, estilo,
/// prohibiciones) sin tener que repetirlo en cada sesión.
///
/// Precedencia (el primero que existe gana para cada nombre, y se concatenan
/// los que haya, en este orden):
/// 1. `AGENTS.md` — estándar abierto de instrucciones para agentes.
/// 2. `CLAUDE.md` — convención de Claude Code, muy extendida.
/// 3. `.chronox/instructions.md` — propio de Chronox AI.
///
/// El contenido se recorta a [maxChars] para no quemar el contexto: un
/// `AGENTS.md` de 200 KB no ayuda a nadie.
abstract final class ProjectInstructions {
  static const List<String> candidates = <String>[
    'AGENTS.md',
    'CLAUDE.md',
    '.chronox/instructions.md',
  ];

  /// Tope de caracteres por fichero. Suficiente para instrucciones serias,
  /// insuficiente para arrastrar un manual entero al contexto.
  static const int maxChars = 12000;

  /// Carga las instrucciones disponibles en [workspaceDir].
  ///
  /// Devuelve `''` si no hay ninguno: el llamador decide si merece la pena
  /// añadir la sección al prompt. Nunca lanza: un fichero ilegible no debe
  /// impedir abrir la sesión.
  static Future<String> load(final Directory workspaceDir) async {
    final parts = <String>[];
    for (final name in candidates) {
      try {
        final file = File(p.join(workspaceDir.path, name));
        if (!await file.exists()) continue;
        var content = await file.readAsString();
        content = content.trim();
        if (content.isEmpty) continue;
        if (content.length > maxChars) {
          content =
              '${content.substring(0, maxChars)}\n…[instrucciones truncadas]';
        }
        parts.add('--- $name ---\n$content');
      } catch (_) {
        // Fichero ilegible o con encoding raro: se ignora y se sigue.
      }
    }
    return parts.join('\n\n');
  }
}
