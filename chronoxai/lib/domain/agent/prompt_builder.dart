import '../plugins/plugin_api.dart';
import 'agent_events.dart';
import 'session_log.dart';

/// Construye el system prompt a partir del modo activo, las herramientas
/// disponibles y el estado de la sesión.
///
/// Equivalente al `ctx.systemPrompt` de DeepSeek Harness: la asamblea es un
/// componente propio, no una cadena incrustada en el motor. Eso permite que un
/// plugin aporte secciones (sus `PluginSkill`) sin tocar el bucle.
abstract final class PromptBuilder {
  /// Texto común a todos los modos.
  static const String base = '''
Eres Chronox AI, un agente de codificación que se ejecuta en un dispositivo
Android con un contenedor Linux (Debian) propio.

Entorno:
- El proyecto vive en /workspace, dentro del contenedor.
- Tienes un shell completo: apt, git, python3, node y cualquier paquete que
  instales. No es un intérprete simulado: los comandos se ejecutan de verdad.
- No hay systemd: los procesos en segundo plano se lanzan directamente y se
  detienen con señales.
- No hay acceso a la GPU ni a la interfaz gráfica del dispositivo.

Cómo trabajar:
1. Antes de editar un fichero, léelo. Antes de crear uno, comprueba si ya existe.
2. Prefiere `edit` (reemplazo exacto) para cambios pequeños; `write` solo para
   ficheros nuevos o reescrituras completas.
3. Verifica lo que haces. Si escribes código, ejecútalo. Si arreglas un bug,
   reproduce el fallo antes y confirma que ya no ocurre después.
4. Para tareas de más de tres pasos, usa `todo_write` y mantén la lista al día.
5. Si una tarea es grande o destructiva, presenta un plan con `exit_plan_mode`
   antes de actuar.
6. No inventes rutas ni APIs: comprueba con `glob`, `grep` o `ls`.
7. Si una herramienta falla, analiza el error concreto, busca una corrección y
   vuelve a ejecutar la herramienta para verificar; no abandones tras el primer
   fallo. No repitas sin cambios una acción que falló por la misma causa.
8. Si falta un ejecutable o paquete necesario, identifica la distribución y el
   gestor de paquetes, explica brevemente por qué hace falta y solicita aprobación
   del usuario antes de instalarlo. Instala solo lo mínimo necesario y después
   reintenta el comando original. Nunca eludas la aprobación ejecutando la
   instalación mediante otra herramienta.

Estilo:
- Responde en el idioma del usuario.
- Sé breve. No expliques lo que el usuario ya ve en la salida de tus comandos.
- Cuando termines, di qué hiciste y qué queda pendiente, sin adornos.
''';

  /// Secciones específicas de cada modo, alineadas con los de DeepSeek Harness.
  static String modeSection(final String modeId) {
    return switch (modeId) {
      'minimal' => '''
Modo Minimal: solo dispones de un shell y un editor de reemplazo exacto. No hay
búsqueda, ni planificación, ni subagentes. Resuelve la tarea con lo que tienes y
no pidas herramientas que no existen.
''',
      'code' => '''
Modo Code (PTC): además de las herramientas individuales tienes `run_code`, que
ejecuta un programa Python dentro del contenedor. Úsalo cuando varios pasos
dependan unos de otros (buscar, leer, transformar, escribir, verificar): un solo
programa ahorra idas y vueltas y evita perder contexto entre llamadas. Imprime un
resumen al final; el programa no debe dejar procesos en segundo plano.
''',
      'creator' => '''
Modo Creator: puedes inspeccionar el runtime con `cordis_inspect` y gestionar
plugins con `plugin_manager`. Los plugins de Chronox AI declaran las capacidades
que usan; si un plugin pide `shell`, hay que avisar al usuario de que podrá
ejecutar comandos. Un plugin puede aportar herramientas, skills, modos y su
propia pantalla.
''',
      _ => '',
    };
  }

  /// Construye el prompt completo.
  static String build({
    required final String modeId,
    required final List<PluginTool> tools,
    final SessionLog? log,
    final String? projectInstructions,
    final Map<String, Object?> context = const <String, Object?>{},
  }) {
    final buffer = StringBuffer(base);

    final section = modeSection(modeId);
    if (section.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(section.trim());
    }

    // Instrucciones del proyecto (AGENTS.md / CLAUDE.md): van después de la
    // sección del modo y antes del catálogo de herramientas, porque son lo más
    // específico del proyecto en el que se trabaja.
    if (projectInstructions != null && projectInstructions.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Instrucciones del proyecto (AGENTS.md / CLAUDE.md):')
        ..writeln(projectInstructions.trim());
    }

    if (tools.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Herramientas disponibles:');
      for (final tool in tools) {
        buffer.writeln('- ${tool.name}: ${_firstLine(tool.description)}');
      }
    }

    if (log != null) {
      final stats = log.stats();
      if (stats.turns > 0) {
        buffer
          ..writeln()
          ..writeln(
            'Estado de la sesión: ${stats.turns} turnos, ${stats.steps} pasos, '
            '${stats.toolCalls} llamadas a herramientas'
            '${stats.failedTools > 0 ? ' (${stats.failedTools} fallidas)' : ''}.',
          );
      }
    }

    for (final entry in context.entries) {
      buffer
        ..writeln()
        ..writeln('${entry.key}: ${entry.value}');
    }

    return buffer.toString().trim();
  }

  static String _firstLine(final String text) {
    final newline = text.indexOf('\n');
    return newline == -1 ? text : text.substring(0, newline);
  }

  /// Convierte eventos en una transcripción compacta para pedir un resumen.
  static String transcriptForSummary(final List<SessionEvent> events) {
    final buffer = StringBuffer();
    for (final event in events) {
      switch (event) {
        case UserMessageEvent(:final text):
          buffer.writeln('USUARIO: ${_clip(text)}');
        case AssistantMessageEvent(:final text) when text.trim().isNotEmpty:
          buffer.writeln('ASISTENTE: ${_clip(text)}');
        case ToolCallEvent(:final name, :final arguments):
          buffer.writeln('  → $name(${_clip(arguments.toString(), 120)})');
        case ToolResultEvent(:final content, :final isError):
          buffer.writeln(
            '  ← ${isError ? 'ERROR' : 'OK'}: ${_clip(content, 200)}',
          );
        default:
          break;
      }
    }
    return buffer.toString();
  }

  /// Resumen sin modelo: se usa cuando no hay proveedor disponible o falla.
  ///
  /// Es determinista a propósito. Un resumen pobre pero fiable es mejor que
  /// perder la conversación porque el proveedor de resumen falló.
  static String deterministicSummary(final List<SessionEvent> events) {
    final userMessages = <String>[];
    final filesTouched = <String>{};
    final commands = <String>[];
    var failedTools = 0;

    for (final event in events) {
      switch (event) {
        case UserMessageEvent(:final text):
          userMessages.add(_clip(text, 160));
        case ToolCallEvent(:final name, :final arguments):
          if (name == 'bash' && arguments['command'] != null) {
            commands.add(_clip(arguments['command'].toString(), 100));
          }
          final path = arguments['path'];
          if (path is String) filesTouched.add(path);
        case ToolResultEvent(:final isError):
          if (isError) failedTools++;
        default:
          break;
      }
    }

    final buffer = StringBuffer();
    if (userMessages.isNotEmpty) {
      buffer.writeln('Peticiones del usuario:');
      for (final message in userMessages.take(5)) {
        buffer.writeln('- $message');
      }
    }
    if (filesTouched.isNotEmpty) {
      buffer.writeln('Ficheros tocados: ${filesTouched.take(15).join(', ')}.');
    }
    if (commands.isNotEmpty) {
      buffer.writeln('Comandos ejecutados: ${commands.take(8).join(' | ')}.');
    }
    if (failedTools > 0) {
      buffer.writeln('Hubo $failedTools ejecuciones fallidas.');
    }
    return buffer.isEmpty
        ? 'Sin actividad relevante.'
        : buffer.toString().trim();
  }

  static String _clip(final String text, [final int max = 300]) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
