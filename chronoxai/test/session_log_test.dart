import 'dart:io';

import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/session_log.dart';
import 'package:chronoxai/domain/modes/work_modes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chronox-session-test-');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('SessionLog', () {
    test('crea la sesión con un evento inicial', () async {
      final log = await SessionLog.open(tempDir, 's1', model: 'deepseek-chat');

      expect(log.length, 1);
      expect(log.events.first, isA<SessionCreatedEvent>());
      await log.close();
    });

    test('persiste y recarga los eventos', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(const UserMessageEvent(text: 'hola'));
      await log.append(const AssistantMessageEvent(text: 'buenas'));
      await log.close();

      final reopened = await SessionLog.open(tempDir, 's1');
      expect(reopened.length, 3);
      expect(reopened.events[1], isA<UserMessageEvent>());
      expect(reopened.events[2], isA<AssistantMessageEvent>());
      await reopened.close();
    });

    test('persiste el estado activo de plugins propio de la sesión', () async {
      final log = await SessionLog.open(tempDir, 's1', modeId: WorkModes.standard);
      await log.append(
        const PluginStateEvent(pluginId: 'core-search', enabled: false),
      );
      await log.append(
        const PluginStateEvent(pluginId: 'core-fs', enabled: true),
      );
      await log.close();

      final reopened = await SessionLog.open(tempDir, 's1');
      final states = reopened.events.whereType<PluginStateEvent>().toList();
      expect(states, hasLength(2));
      expect(states.lastWhere((final state) => state.pluginId == 'core-search').enabled,
          isFalse);
      expect(states.lastWhere((final state) => state.pluginId == 'core-fs').enabled,
          isTrue);
      await reopened.close();
    });

    test('descarta líneas corruptas sin abortar la sesión', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.close();

      // Simula un proceso que murió a media escritura.
      final file = File('${tempDir.path}/s1.jsonl');
      await file.writeAsString(
          '{"type":"user/message","data":{"text":"ok"}}\n'
          '{"type":"assistant/mes',
          mode: FileMode.append);

      final reopened = await SessionLog.open(tempDir, 's1');
      expect(reopened.length, 2); // created + el bueno
      await reopened.close();
    });

    test('el título sale del primer mensaje del usuario', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log
          .append(const UserMessageEvent(text: 'arregla el bug del login'));

      expect(log.title, 'arregla el bug del login');
      await log.close();
    });

    test('el título prefiere el evento de título explícito', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(const UserMessageEvent(text: 'mensaje largo'));
      await log.append(const SessionTitleEvent(title: 'Arreglo de login'));

      expect(log.title, 'Arreglo de login');
      await log.close();
    });

    test('recorta títulos demasiado largos', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(UserMessageEvent(text: 'x' * 100));

      expect(log.title.length, lessThanOrEqualTo(48));
      expect(log.title, endsWith('…'));
      await log.close();
    });

    test('rewind trunca el log de forma persistente', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(const UserMessageEvent(text: 'uno'));
      await log.append(const UserMessageEvent(text: 'dos'));
      expect(log.length, 3);

      await log.rewindTo(2);
      expect(log.length, 2);
      await log.close();

      final reopened = await SessionLog.open(tempDir, 's1');
      expect(reopened.length, 2);
      await reopened.close();
    });

    test('rewind fuera de rango lanza', () async {
      final log = await SessionLog.open(tempDir, 's1');
      expect(() => log.rewindTo(99), throwsArgumentError);
      await log.close();
    });

    test('fork copia el prefijo y diverge', () async {
      final log = await SessionLog.open(tempDir, 'original');
      await log.append(const UserMessageEvent(text: 'mensaje base'));

      final fork = await log.fork(tempDir, 'copia');
      expect(fork.length, 2);
      expect((fork.events[1] as UserMessageEvent).text, 'mensaje base');

      await fork.append(const UserMessageEvent(text: 'solo en el fork'));
      expect(fork.length, 3);
      expect(log.length, 2); // el original no cambia
      await log.close();
      await fork.close();
    });

    test('la historia visible se corta en la última compactación', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(const UserMessageEvent(text: 'viejo'));
      await log.append(
        const CompactionEvent(
          summary: 'resumen de lo anterior',
          replacedEventCount: 2,
          tokensBefore: 1000,
          tokensAfter: 100,
        ),
      );
      await log.append(const UserMessageEvent(text: 'nuevo'));

      final visible = log.modelVisibleHistory();
      expect(visible.length, 2);
      expect(visible.first, isA<CompactionEvent>());
      await log.close();
    });

    test('las estadísticas agregan turns, steps, tools y tokens', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(const TurnStartEvent(turnId: 't1'));
      await log.append(const StepStartEvent(stepIndex: 0));
      await log.append(
        const ToolCallEvent(
            callId: 'c1', name: 'bash', arguments: <String, Object?>{}),
      );
      await log.append(
        const ToolResultEvent(
          callId: 'c1',
          name: 'bash',
          content: 'ok',
          durationMs: 120,
        ),
      );
      await log.append(
        const StepEndEvent(
          stepIndex: 0,
          inputTokens: 100,
          outputTokens: 50,
          durationMs: 800,
          toolTimeMs: 120,
          timeToFirstTokenMs: 300,
        ),
      );

      final stats = log.stats();
      expect(stats.turns, 1);
      expect(stats.steps, 1);
      expect(stats.toolCalls, 1);
      expect(stats.failedTools, 0);
      expect(stats.totalTokens, 150);
      expect(stats.medianTimeToFirstTokenMs, 300);
      await log.close();
    });

    test('cuenta las herramientas fallidas', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(
        const ToolResultEvent(
          callId: 'c1',
          name: 'bash',
          content: 'error',
          isError: true,
        ),
      );

      expect(log.stats().failedTools, 1);
      await log.close();
    });

    test('exporta a Markdown legible', () async {
      final log = await SessionLog.open(tempDir, 's1');
      await log.append(const UserMessageEvent(text: 'haz algo'));
      await log.append(const AssistantMessageEvent(text: 'hecho'));

      final markdown = log.exportMarkdown();
      expect(markdown, contains('# '));
      expect(markdown, contains('## Usuario'));
      expect(markdown, contains('haz algo'));
      expect(markdown, contains('## Asistente'));
      await log.close();
    });

    test('emite los cambios a los suscriptores', () async {
      final log = await SessionLog.open(tempDir, 's1');
      final received = <SessionEvent>[];
      final disposable = log.listen(received.add);

      await log.append(const UserMessageEvent(text: 'evento'));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      disposable();
      await log.close();
    });
  });

  group('WorkModes', () {
    test('los cuatro modos existen', () {
      expect(WorkModes.all.map((final m) => m.id), <String>[
        WorkModes.standard,
        WorkModes.code,
        WorkModes.minimal,
        WorkModes.creator,
      ]);
    });

    test('cada modo tiene una lista de plugins no vacía', () {
      for (final mode in WorkModes.all) {
        expect(mode.pluginIds, isNotEmpty);
        expect(WorkModes.pluginsFor(mode.id), isNotEmpty);
      }
    });

    test('Minimal solo monta dos plugins', () {
      expect(WorkModes.pluginsFor(WorkModes.minimal), hasLength(2));
      expect(
        WorkModes.pluginsFor(WorkModes.minimal),
        <String>['base-shell', 'base-editor'],
      );
    });

    test('Code incluye el plugin de PTC', () {
      expect(WorkModes.pluginsFor(WorkModes.code), contains('code-mode'));
      expect(WorkModes.pluginsFor(WorkModes.standard),
          isNot(contains('code-mode')));
    });

    test('Creator incluye inspección y gestor de plugins', () {
      final plugins = WorkModes.pluginsFor(WorkModes.creator);
      expect(plugins, contains('creator-inspect'));
      expect(plugins, contains('creator-plugin-manager'));
    });

    test('los modos declaran un pluginSet coherente con su lista', () {
      for (final mode in WorkModes.all) {
        expect(mode.pluginIds, WorkModes.pluginSets[mode.id]);
      }
    });

    test('un id desconocido cae en Standard', () {
      expect(WorkModes.byId('inventado').id, WorkModes.standard);
    });
  });
}
