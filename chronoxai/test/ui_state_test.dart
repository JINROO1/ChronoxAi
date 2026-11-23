import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/ui/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transcriptOf', () {
    test('ordena mensajes y agrupa la llamada con su resultado', () {
      const events = <SessionEvent>[
        UserMessageEvent(text: 'arregla el test'),
        AssistantMessageEvent(text: 'Voy a leerlo.'),
        ToolCallEvent(
          callId: 'c1',
          name: 'read',
          arguments: <String, Object?>{'path': '/workspace/a.dart'},
        ),
        ToolResultEvent(
          callId: 'c1',
          name: 'read',
          content: 'void main() {}',
        ),
      ];

      final entries = transcriptOf(events);

      expect(entries, hasLength(3));
      expect(entries[0].kind, TranscriptKind.user);
      expect(entries[1].kind, TranscriptKind.assistant);
      expect(entries[2].kind, TranscriptKind.tool);
      expect(entries[2].title, 'read');
      expect(entries[2].text, contains('/workspace/a.dart'));
      expect(entries[2].text, contains('void main'));
      expect(entries[2].isPending, isFalse);
    });

    test('una herramienta sin resultado queda pendiente', () {
      const events = <SessionEvent>[
        ToolCallEvent(
          callId: 'c1',
          name: 'bash',
          arguments: <String, Object?>{'command': 'ls'},
        ),
      ];

      final entry = transcriptOf(events).single;

      expect(entry.isPending, isTrue);
      expect(entry.text, 'ls');
    });

    test('un resultado con error se marca como error', () {
      const events = <SessionEvent>[
        ToolCallEvent(
          callId: 'c1',
          name: 'write',
          arguments: <String, Object?>{'path': '/workspace/b.dart'},
        ),
        ToolResultEvent(
          callId: 'c1',
          name: 'write',
          content: 'permiso denegado',
          isError: true,
        ),
      ];

      expect(transcriptOf(events).single.isError, isTrue);
    });

    test('un mensaje del asistente vacío no genera burbuja', () {
      const events = <SessionEvent>[
        AssistantMessageEvent(
          text: '   ',
          toolCallIds: <String>['c1'],
        ),
      ];

      expect(transcriptOf(events), isEmpty);
    });

    test('la compactación aparece como aviso', () {
      const events = <SessionEvent>[
        CompactionEvent(
          summary: 'Se instaló git y se arregló el test.',
          replacedEventCount: 20,
          tokensBefore: 50000,
          tokensAfter: 200,
        ),
      ];

      final entry = transcriptOf(events).single;

      expect(entry.kind, TranscriptKind.notice);
      expect(entry.text, contains('git'));
    });
  });

  group('ProviderSettings', () {
    test('sin clave no está configurado', () {
      const settings = ProviderSettings(model: 'deepseek-chat');
      expect(settings.isConfigured, isFalse);
    });

    test('con clave y modelo está configurado', () {
      const settings = ProviderSettings(apiKey: 'sk-x', model: 'm');
      expect(settings.isConfigured, isTrue);
    });

    test('una clave en blanco no cuenta como configurada', () {
      const settings = ProviderSettings(apiKey: '   ', model: 'm');
      expect(settings.isConfigured, isFalse);
    });

    test('copyWith conserva lo que no cambia', () {
      const settings = ProviderSettings(
        baseUrl: 'https://a/v1',
        model: 'm',
        apiKey: 'k',
      );
      final updated = settings.copyWith(model: 'otro');
      expect(updated.baseUrl, 'https://a/v1');
      expect(updated.apiKey, 'k');
      expect(updated.model, 'otro');
    });
  });
}
