import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../plugins/plugin_api.dart' show Disposable;
import 'agent_events.dart';

/// Log de sesión *append-only* en JSONL.
///
/// Es la única fuente de verdad de la sesión: la UI, el contexto del modelo, el
/// fork, el rewind y la telemetría se derivan de aquí. Principio tomado de dsh:
/// *"model-visible means logged"* — todo lo que llega al modelo debe poder
/// reconstruirse desde el log.
///
/// Por qué un fichero y no una base de datos: en móvil, un `append` secuencial es
/// atómico y barato, sobrevive a la muerte del proceso, y se puede inspeccionar
/// con `cat`. Un JSON truncado en la última línea se descarta al cargar.
class SessionLog {
  SessionLog._({
    required this.sessionId,
    required final File file,
    required final List<SessionEvent> events,
  }) : _file = file,
       _events = events;

  /// Abre una sesión existente o crea una nueva.
  static Future<SessionLog> open(
    final Directory sessionDir,
    final String sessionId, {
    final String modeId = 'standard',
    final String model = '',
  }) async {
    await sessionDir.create(recursive: true);
    final file = File(p.join(sessionDir.path, '$sessionId.jsonl'));
    final events = <SessionEvent>[];

    if (await file.exists()) {
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, Object?>;
          final event = SessionEvent.fromJson(json);
          if (event != null) events.add(event);
        } catch (_) {
          // Línea corrupta (proceso muerto a media escritura): se descarta.
          // Perder el último evento es aceptable; abortar la sesión no.
        }
      }
    }

    final log = SessionLog._(sessionId: sessionId, file: file, events: events);

    if (events.isEmpty) {
      await log.append(
        SessionCreatedEvent(
          sessionId: sessionId,
          modeId: modeId,
          model: model,
          createdAt: DateTime.now(),
        ),
      );
    }

    return log;
  }

  final String sessionId;
  final File _file;
  final List<SessionEvent> _events;

  final StreamController<SessionEvent> _changes =
      StreamController<SessionEvent>.broadcast();

  /// Eventos persistidos, en orden.
  List<SessionEvent> get events => List<SessionEvent>.unmodifiable(_events);

  /// Stream de eventos nuevos (para que la UI se reconstruya sin polling).
  Stream<SessionEvent> get changes => _changes.stream;

  int get length => _events.length;

  /// Añade un evento y lo persiste.
  ///
  /// El `await` garantiza que el fichero está escrito antes de devolver: si el
  /// proceso muere justo después, el log no miente sobre lo que pasó.
  Future<void> append(final SessionEvent event) async {
    _events.add(event);
    await _file.writeAsString(
      '${jsonEncode(<String, Object?>{
        'type': event.eventType,
        'at': DateTime.now().toIso8601String(),
        'data': event.toJson(),
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
    if (!_changes.isClosed) _changes.add(event);
  }

  /// Título de la sesión, si un proveedor de títulos lo generó.
  String get title {
    for (final event in _events.reversed) {
      if (event is SessionTitleEvent) return event.title;
    }
    // Sin título: se usa el primer mensaje del usuario, recortado.
    for (final event in _events) {
      if (event is UserMessageEvent && event.text.trim().isNotEmpty) {
        final text = event.text.trim().replaceAll('\n', ' ');
        return text.length <= 48 ? text : '${text.substring(0, 47)}…';
      }
    }
    return 'Sesión sin título';
  }

  /// Reconstruye la conversación que ve el modelo.
  ///
  /// Se detiene en el último evento de compactación: lo anterior se sustituye
  /// por el resumen, que es exactamente el efecto buscado al compactar.
  List<SessionEvent> modelVisibleHistory() {
    var start = 0;
    for (var i = _events.length - 1; i >= 0; i--) {
      if (_events[i] is CompactionEvent) {
        start = i;
        break;
      }
    }
    return _events.sublist(start);
  }

  /// Telemetría agregada, equivalente al panel *Trajectory* de dsh.
  SessionStats stats() {
    var turns = 0;
    var steps = 0;
    var toolCalls = 0;
    var failedTools = 0;
    var inputTokens = 0;
    var outputTokens = 0;
    var modelTimeMs = 0;
    var toolTimeMs = 0;
    var firstTokenMs = <int>[];

    for (final event in _events) {
      switch (event) {
        case TurnStartEvent():
          turns++;
        case StepStartEvent():
          steps++;
        case ToolCallEvent():
          toolCalls++;
        case ToolResultEvent(:final isError, :final durationMs):
          if (isError) failedTools++;
          toolTimeMs += durationMs;
        case final StepEndEvent step:
          inputTokens += step.inputTokens;
          outputTokens += step.outputTokens;
          modelTimeMs += step.durationMs;
          toolTimeMs += step.toolTimeMs;
          final ttft = step.timeToFirstTokenMs;
          if (ttft != null) firstTokenMs.add(ttft);
        default:
          break;
      }
    }

    return SessionStats(
      turns: turns,
      steps: steps,
      toolCalls: toolCalls,
      failedTools: failedTools,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      modelTimeMs: modelTimeMs,
      toolTimeMs: toolTimeMs,
      medianTimeToFirstTokenMs: _median(firstTokenMs),
    );
  }

  static int? _median(final List<int> values) {
    if (values.isEmpty) return null;
    final sorted = List<int>.from(values)..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// Trunca el log a [eventCount] eventos (rewind).
  ///
  /// Reescribe el fichero completo: es la única forma de que un rewind sea
  /// consistente si el proceso muere a mitad.
  Future<void> rewindTo(final int eventCount) async {
    if (eventCount < 0 || eventCount > _events.length) {
      throw ArgumentError('eventCount fuera de rango: $eventCount');
    }
    final kept = _events.sublist(0, eventCount);
    await _rewrite(kept);
  }

  /// Crea una sesión nueva con el prefijo de esta (fork).
  ///
  /// El fork comparte la historia hasta el punto actual y diverge después: así
  /// se puede explorar una alternativa sin perder el hilo original.
  Future<SessionLog> fork(
    final Directory sessionDir,
    final String newSessionId, {
    int? atEventCount,
  }) async {
    final count = atEventCount ?? _events.length;
    if (count < 0 || count > _events.length) {
      throw ArgumentError('atEventCount fuera de rango: $count');
    }

    await sessionDir.create(recursive: true);
    final file = File(p.join(sessionDir.path, '$newSessionId.jsonl'));
    final prefix = _events.sublist(0, count);

    final buffer = StringBuffer();
    for (final event in prefix) {
      buffer.writeln(
        jsonEncode(<String, Object?>{
          'type': event.eventType,
          'at': DateTime.now().toIso8601String(),
          'data': event.toJson(),
        }),
      );
    }
    await file.writeAsString(buffer.toString(), flush: true);

    return SessionLog.open(sessionDir, newSessionId);
  }

  Future<void> _rewrite(final List<SessionEvent> kept) async {
    final buffer = StringBuffer();
    for (final event in kept) {
      buffer.writeln(
        jsonEncode(<String, Object?>{
          'type': event.eventType,
          'at': DateTime.now().toIso8601String(),
          'data': event.toJson(),
        }),
      );
    }
    await _file.writeAsString(buffer.toString(), flush: true);
    _events
      ..clear()
      ..addAll(kept);
  }

  /// Exporta la sesión como Markdown legible.
  String exportMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# ${title}')
      ..writeln()
      ..writeln('_Sesión `${sessionId}` · ${_events.length} eventos_')
      ..writeln();

    for (final event in _events) {
      switch (event) {
        case UserMessageEvent(:final text):
          buffer
            ..writeln('## Usuario')
            ..writeln()
            ..writeln(text)
            ..writeln();
        case AssistantMessageEvent(:final text) when text.trim().isNotEmpty:
          buffer
            ..writeln('## Asistente')
            ..writeln()
            ..writeln(text)
            ..writeln();
        case ToolCallEvent(:final name, :final arguments):
          buffer
            ..writeln('### 🔧 $name')
            ..writeln()
            ..writeln('```json')
            ..writeln(const JsonEncoder.withIndent('  ').convert(arguments))
            ..writeln('```')
            ..writeln();
        case ToolResultEvent(:final name, :final content, :final isError):
          buffer
            ..writeln('**Resultado de `$name`**${isError ? ' (error)' : ''}')
            ..writeln()
            ..writeln('```')
            ..writeln(content)
            ..writeln('```')
            ..writeln();
        case CompactionEvent(:final summary):
          buffer
            ..writeln('> **Contexto compactado:** $summary')
            ..writeln();
        default:
          break;
      }
    }
    return buffer.toString();
  }

  Future<void> close() async {
    await _changes.close();
  }

  /// Suscripción a los cambios del log (se cancela con el `Disposable`).
  Disposable listen(final void Function(SessionEvent) handler) {
    final sub = changes.listen(handler);
    return sub.cancel;
  }
}

/// Métricas agregadas de una sesión.
class SessionStats {
  const SessionStats({
    required this.turns,
    required this.steps,
    required this.toolCalls,
    required this.failedTools,
    required this.inputTokens,
    required this.outputTokens,
    required this.modelTimeMs,
    required this.toolTimeMs,
    required this.medianTimeToFirstTokenMs,
  });

  final int turns;
  final int steps;
  final int toolCalls;
  final int failedTools;
  final int inputTokens;
  final int outputTokens;
  final int modelTimeMs;
  final int toolTimeMs;
  final int? medianTimeToFirstTokenMs;

  int get totalTokens => inputTokens + outputTokens;

  Duration get totalTime => Duration(milliseconds: modelTimeMs + toolTimeMs);

  @override
  String toString() =>
      'SessionStats(turns: $turns, steps: $steps, tools: $toolCalls'
      '($failedTools fallidas), tokens: $totalTokens, '
      'ttft: ${medianTimeToFirstTokenMs ?? '-'}ms)';
}
