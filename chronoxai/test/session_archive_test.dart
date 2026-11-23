import 'dart:io';

import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/session_archive.dart';
import 'package:chronoxai/domain/agent/session_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chronox-archive-');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('lista sesiones con título, métricas y búsqueda en historial', () async {
    final log = await SessionLog.open(dir, 'session-a');
    await log.append(const UserMessageEvent(text: 'Analiza el proyecto Chronox'));
    await log.append(const SessionTitleEvent(title: 'Revisión del proyecto'));
    await log.append(const TurnStartEvent(turnId: 't1'));
    await log.append(const StepStartEvent(stepIndex: 0));
    await log.append(const StepEndEvent(
      stepIndex: 0,
      inputTokens: 11,
      outputTokens: 7,
      durationMs: 120,
      toolTimeMs: 30,
      timeToFirstTokenMs: 45,
    ));
    await log.close();

    final archive = SessionArchive(dir);
    final all = await archive.list();
    expect(all, hasLength(1));
    expect(all.single.title, 'Revisión del proyecto');
    expect(all.single.stats.turns, 1);
    expect(all.single.stats.totalTokens, 18);
    expect(all.single.stats.medianTimeToFirstTokenMs, 45);

    expect((await archive.list(query: 'CHRONOX')), hasLength(1));
    expect(await archive.list(query: 'no existe'), isEmpty);
  });

  test('ignora JSONL corrupto sin modificar el fichero', () async {
    final file = File('${dir.path}/bad.jsonl');
    await file.writeAsString('{no es json}\n');
    final before = await file.readAsString();

    expect(await SessionArchive(dir).list(), isEmpty);
    expect(await file.readAsString(), before);
  });
}
