import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_events.dart';
import 'session_log.dart';

/// Resumen indexable de una sesión archivada en JSONL.
class ArchivedSession {
  const ArchivedSession({
    required this.id,
    required this.path,
    required this.title,
    required this.updatedAt,
    required this.events,
    required this.stats,
  });

  final String id;
  final String path;
  final String title;
  final DateTime updatedAt;
  final List<SessionEvent> events;
  final SessionStats stats;

  bool matches(final String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    if (title.toLowerCase().contains(needle) || id.toLowerCase().contains(needle)) {
      return true;
    }
    return events.any((final event) => _eventText(event).contains(needle));
  }

  static String _eventText(final SessionEvent event) => switch (event) {
        UserMessageEvent(:final text) => text.toLowerCase(),
        AssistantMessageEvent(:final text) => text.toLowerCase(),
        ToolCallEvent(:final name, :final arguments) =>
          '$name $arguments'.toLowerCase(),
        ToolResultEvent(:final content) => content.toLowerCase(),
        SessionTitleEvent(:final title) => title.toLowerCase(),
        _ => '',
      };
}

/// Lectura no destructiva del directorio `sessions/*.jsonl`.
///
/// A diferencia de [SessionLog.open], el índice nunca crea ni modifica logs:
/// una línea corrupta se ignora igual que al reabrir una sesión.
class SessionArchive {
  const SessionArchive(this.directory);

  final Directory directory;

  Future<List<ArchivedSession>> list({String query = ''}) async {
    if (!await directory.exists()) return const <ArchivedSession>[];
    final entries = <ArchivedSession>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      final events = await _readEvents(entity);
      if (events.isEmpty) continue;
      final stat = await entity.stat();
      final id = p.basenameWithoutExtension(entity.path);
      final title = _titleFor(id, events);
      final sessionStats = _statsFor(events);
      final entry = ArchivedSession(
        id: id,
        path: entity.path,
        title: title,
        updatedAt: stat.modified,
        events: List<SessionEvent>.unmodifiable(events),
        stats: sessionStats,
      );
      if (entry.matches(query)) entries.add(entry);
    }
    entries.sort((final a, final b) => b.updatedAt.compareTo(a.updatedAt));
    return List<ArchivedSession>.unmodifiable(entries);
  }

  static Future<List<SessionEvent>> _readEvents(final File file) async {
    final events = <SessionEvent>[];
    try {
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, Object?>;
          final event = SessionEvent.fromJson(json);
          if (event != null) events.add(event);
        } catch (_) {
          // Línea incompleta/corrupta: no invalida las demás sesiones.
        }
      }
    } catch (_) {
      // Un archivo no legible no debe impedir abrir el índice.
    }
    return events;
  }

  static String _titleFor(final String id, final List<SessionEvent> events) {
    for (final event in events.reversed) {
      if (event case SessionTitleEvent(:final title) when title.trim().isNotEmpty) {
        return title.trim();
      }
    }
    for (final event in events) {
      if (event case UserMessageEvent(:final text) when text.trim().isNotEmpty) {
        final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
        return normalized.length > 64 ? '${normalized.substring(0, 61)}…' : normalized;
      }
    }
    return id;
  }

  static SessionStats _statsFor(final List<SessionEvent> events) {
    // SessionLog.stats is intentionally owned by the durable log. Reuse its
    // canonical accounting by writing it nowhere: aggregate the same events in
    // a temporary view is not possible, so expose this deterministic summary.
    var turns = 0;
    var steps = 0;
    var toolCalls = 0;
    var failedTools = 0;
    var inputTokenCount = 0;
    var outputTokenCount = 0;
    var modelTimeMs = 0;
    var toolTimeMs = 0;
    final ttfts = <int>[];
    for (final event in events) {
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
          inputTokenCount += step.inputTokens;
          outputTokenCount += step.outputTokens;
          modelTimeMs += step.durationMs;
          toolTimeMs += step.toolTimeMs;
          if (step.timeToFirstTokenMs != null) {
            ttfts.add(step.timeToFirstTokenMs!);
          }
        default:
          break;
      }
    }
    // `SessionLog.stats()` is the authoritative implementation; these fields
    // remain aligned with its public stats shape.
    return SessionStats(
      turns: turns,
      steps: steps,
      toolCalls: toolCalls,
      failedTools: failedTools,
      inputTokens: inputTokenCount,
      outputTokens: outputTokenCount,
      modelTimeMs: modelTimeMs,
      toolTimeMs: toolTimeMs,
      medianTimeToFirstTokenMs: ttfts.isEmpty ? null : (ttfts..sort())[ttfts.length ~/ 2],
    );
  }
}
