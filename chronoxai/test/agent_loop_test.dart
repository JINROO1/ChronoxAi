import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chronoxai/domain/agent/agent_events.dart';
import 'package:chronoxai/domain/agent/agent_loop.dart';
import 'package:chronoxai/domain/agent/approval_policy.dart';
import 'package:chronoxai/domain/agent/prompt_builder.dart';
import 'package:chronoxai/domain/agent/session_log.dart';
import 'package:chronoxai/domain/agent/tool_registry.dart';
import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:chronoxai/domain/plugins/plugin_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proveedor falso: devuelve respuestas prefabricadas en orden.
class FakeProvider implements LlmProvider {
  FakeProvider(this.responses);

  final List<LlmResponse> responses;
  int calls = 0;
  int cancelled = 0;

  @override
  String get name => 'fake';

  @override
  String get model => 'fake-model';

  @override
  int? get contextWindow => 128000;

  @override
  Stream<LlmChunk> stream({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    final double? temperature,
    final int? maxTokens,
  }) {
    final index = calls < responses.length ? calls : responses.length - 1;
    calls++;
    final response = responses[index];

    late StreamController<LlmChunk> controller;
    controller = StreamController<LlmChunk>(
      onListen: () async {
        for (final piece in _split(response.content)) {
          if (controller.isClosed) return;
          controller.add(TextChunk(piece));
          await Future<void>.delayed(Duration.zero);
        }
        for (var i = 0; i < response.toolCalls.length; i++) {
          final call = response.toolCalls[i];
          if (controller.isClosed) return;
          controller.add(
            ToolCallChunk(
              index: i,
              id: call.id,
              name: call.name,
              argumentsFragment: call.parseError != null
                  ? '{"path":'
                  : jsonEncode(call.arguments),
            ),
          );
        }
        if (!controller.isClosed) {
          controller.add(
            DoneChunk(usage: response.usage, stopReason: response.stopReason),
          );
          await controller.close();
        }
      },
      onCancel: () async {
        cancelled++;
      },
    );
    return controller.stream;
  }

  static List<String> _split(final String text) {
    if (text.isEmpty) return const <String>[];
    final words = text.split(' ');
    return <String>[
      for (var i = 0; i < words.length; i++)
        i == words.length - 1 ? words[i] : '${words[i]} ',
    ];
  }
}

/// Proveedor que falla las N primeras veces con el error indicado.
class FlakyProvider implements LlmProvider {
  FlakyProvider({required this.failures, required this.result});

  final List<LlmException> failures;
  final LlmResponse result;
  int attempts = 0;

  @override
  String get name => 'flaky';
  @override
  String get model => 'flaky-model';
  @override
  int? get contextWindow => 8000;

  @override
  Stream<LlmChunk> stream({
    required final List<LlmMessage> messages,
    required final List<Map<String, Object?>> tools,
    final double? temperature,
    final int? maxTokens,
  }) {
    attempts++;
    if (attempts <= failures.length) {
      return Stream<LlmChunk>.error(failures[attempts - 1]);
    }
    return Stream<LlmChunk>.fromIterable(<LlmChunk>[
      TextChunk(result.content),
      DoneChunk(usage: result.usage),
    ]);
  }
}

PluginTool tool(
  final String name, {
  required final bool requiresApproval,
  final ToolOutcome Function()? result,
}) =>
    PluginTool(
      name: name,
      description: 'herramienta $name',
      inputSchema: const <String, Object?>{'type': 'object'},
      requiresApproval: requiresApproval,
      execute: (final _) async =>
          result?.call() ?? const ToolOutcome(content: 'ok'),
    );

void main() {
  late Directory tempDir;
  late SessionLog log;
  late ToolRegistry registry;
  late AgentEventBus events;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chronox-loop-');
    log = await SessionLog.open(tempDir, 's1');
    registry = ToolRegistry();
    events = AgentEventBus();
  });

  tearDown(() async {
    await log.close();
    await events.dispose();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  AgentLoop makeLoop(
    final LlmProvider provider, {
    ApprovalPolicy? policy,
    ApprovalHandler? approvalHandler,
    PlanHandler? planHandler,
    Future<String> Function()? loadProjectInstructions,
    AgentConfig config = const AgentConfig(),
  }) {
    return AgentLoop(
      provider: provider,
      registry: registry,
      log: log,
      events: events,
      policy: policy ?? ApprovalPolicy(level: ApprovalLevel.yolo),
      config: config,
      modeId: 'standard',
      approvalHandler: approvalHandler,
      planHandler: planHandler,
      loadProjectInstructions: loadProjectInstructions,
    );
  }

  group('AgentLoop — turno simple', () {
    test('una respuesta sin herramientas cierra el turno', () async {
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: 'Hola, ¿en qué te ayudo?',
          usage: LlmUsage(inputTokens: 10, outputTokens: 5),
        ),
      ]);
      final loop = makeLoop(provider);

      final reason = await loop.runTurn('hola');

      expect(reason, 'completed');
      expect(provider.calls, 1);
      expect(log.events.whereType<UserMessageEvent>(), hasLength(1));
      expect(log.events.whereType<AssistantMessageEvent>().single.text,
          'Hola, ¿en qué te ayudo?');
      expect(log.events.whereType<TurnEndEvent>().single.reason, 'completed');
    });

    test('emite los fragmentos de texto para la UI', () async {
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(content: 'uno dos tres'),
      ]);
      final loop = makeLoop(provider);
      final deltas = <String>[];
      final sub = events.of<AssistantDeltaEvent>().listen(
            (final e) => deltas.add(e.text),
          );

      await loop.runTurn('di algo');
      await Future<void>.delayed(Duration.zero);

      expect(deltas.join(), 'uno dos tres');
      await sub.cancel();
    });

    test('registra tokens y tiempo hasta el primer token', () async {
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: 'ok',
          usage: LlmUsage(inputTokens: 100, outputTokens: 20),
        ),
      ]);
      await makeLoop(provider).runTurn('x');

      final step = log.events.whereType<StepEndEvent>().single;
      expect(step.inputTokens, 100);
      expect(step.outputTokens, 20);
      expect(step.timeToFirstTokenMs, isNotNull);
    });
  });

  group('AgentLoop — herramientas', () {
    test('ejecuta la herramienta y devuelve su resultado al modelo', () async {
      registry.add(
        tool('read',
            requiresApproval: false,
            result: () => const ToolOutcome(content: 'contenido')),
      );
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: '',
          toolCalls: <LlmToolCall>[
            LlmToolCall(
                id: 'c1',
                name: 'read',
                arguments: <String, Object?>{'path': '/a'}),
          ],
        ),
        const LlmResponse(content: 'He leído el fichero.'),
      ]);

      final reason = await makeLoop(provider).runTurn('lee /a');

      expect(reason, 'completed');
      expect(provider.calls, 2);
      expect(log.events.whereType<ToolCallEvent>().single.name, 'read');
      expect(
        log.events.whereType<ToolResultEvent>().single.content,
        'contenido',
      );
    });

    test('una herramienta inexistente devuelve error sin romper el turno',
        () async {
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: '',
          toolCalls: <LlmToolCall>[
            LlmToolCall(
                id: 'c1', name: 'inventada', arguments: <String, Object?>{}),
          ],
        ),
        const LlmResponse(content: 'Lo intento de otra forma.'),
      ]);

      final reason = await makeLoop(provider).runTurn('prueba');

      expect(reason, 'completed');
      final result = log.events.whereType<ToolResultEvent>().single;
      expect(result.isError, isTrue);
      expect(result.content, contains('no existe'));
    });

    test('argumentos ilegibles no se ejecutan: se pide corrección', () async {
      var executed = false;
      registry.add(
        PluginTool(
          name: 'write',
          description: 'escribe',
          inputSchema: const <String, Object?>{'type': 'object'},
          execute: (final _) async {
            executed = true;
            return const ToolOutcome(content: 'ok');
          },
        ),
      );
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: '',
          toolCalls: <LlmToolCall>[
            LlmToolCall(
              id: 'c1',
              name: 'write',
              arguments: <String, Object?>{},
              parseError: 'JSON inválido en los argumentos',
            ),
          ],
        ),
        const LlmResponse(content: 'Corrijo los argumentos.'),
      ]);

      await makeLoop(provider).runTurn('escribe');

      expect(executed, isFalse);
      expect(
        log.events.whereType<ToolResultEvent>().single.content,
        contains('JSON inválido en los argumentos'),
      );
    });

    test('trunca salidas enormes para no quemar el contexto', () async {
      registry.add(
        tool(
          'bash',
          requiresApproval: false,
          result: () =>
              ToolOutcome(content: List<String>.filled(50000, 'x').join()),
        ),
      );
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: '',
          toolCalls: <LlmToolCall>[
            LlmToolCall(id: 'c1', name: 'bash', arguments: <String, Object?>{}),
          ],
        ),
        const LlmResponse(content: 'listo'),
      ]);

      await makeLoop(
        provider,
        config: const AgentConfig(toolOutputBudget: 1000, maxTokens: 256),
      ).runTurn('x');

      final result = log.events.whereType<ToolResultEvent>().single;
      expect(result.truncated, isTrue);
      expect(result.content.length, lessThan(1200));
      expect(result.content, contains('truncada'));
    });

    test('respeta el tope de pasos por turno', () async {
      registry.add(tool('bash', requiresApproval: false));
      // El modelo siempre pide otra herramienta: nunca termina.
      final provider = FakeProvider(<LlmResponse>[
        const LlmResponse(
          content: '',
          toolCalls: <LlmToolCall>[
            LlmToolCall(id: 'c1', name: 'bash', arguments: <String, Object?>{}),
          ],
        ),
      ]);

      final reason = await makeLoop(
        provider,
        config: const AgentConfig(maxStepsPerTurn: 3),
      ).runTurn('bucle');

      expect(reason, 'maxSteps');
      expect(log.events.whereType<ToolCallEvent>().length, 3);
    });
  });

  group('AgentLoop — aprobación', () {
    setUp(() {
      registry.add(tool('bash', requiresApproval: true));
    });

    test('en modo guarded pide permiso y ejecuta si se aprueba', () async {
      var asked = 0;
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                id: 'c1',
                name: 'bash',
                arguments: <String, Object?>{'command': 'ls'},
              ),
            ],
          ),
          const LlmResponse(content: 'hecho'),
        ]),
        policy: ApprovalPolicy(level: ApprovalLevel.guarded),
        approvalHandler: (final request) async {
          asked++;
          return const ApprovalAnswer(approved: true);
        },
      );

      final reason = await loop.runTurn('lista ficheros');

      expect(asked, 1);
      expect(reason, 'completed');
      expect(
        log.events.whereType<ApprovalDecisionEvent>().single.approved,
        isTrue,
      );
    });

    test('si el usuario rechaza, el turno termina en rejected', () async {
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                  id: 'c1', name: 'bash', arguments: <String, Object?>{}),
            ],
          ),
        ]),
        policy: ApprovalPolicy(level: ApprovalLevel.guarded),
        approvalHandler: (final _) async => const ApprovalAnswer.denied(),
      );

      final reason = await loop.runTurn('borra todo');

      expect(reason, 'rejected');
      expect(log.events.whereType<ToolCallEvent>(), hasLength(1));
      // No se ejecutó: no hay resultado de éxito.
      final result = log.events.whereType<ToolResultEvent>().single;
      expect(result.isError, isTrue);
      expect(result.content, contains('rechazó'));
    });

    test('sin handler de aprobación se rechaza (fallar hacia lo seguro)',
        () async {
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                  id: 'c1', name: 'bash', arguments: <String, Object?>{}),
            ],
          ),
        ]),
        policy: ApprovalPolicy(level: ApprovalLevel.guarded),
      );

      expect(await loop.runTurn('x'), 'rejected');
    });

    test('"recordar para esta sesión" evita la segunda pregunta', () async {
      var asked = 0;
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                  id: 'c1', name: 'bash', arguments: <String, Object?>{}),
            ],
          ),
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                  id: 'c2', name: 'bash', arguments: <String, Object?>{}),
            ],
          ),
          const LlmResponse(content: 'fin'),
        ]),
        policy: ApprovalPolicy(level: ApprovalLevel.guarded),
        approvalHandler: (final _) async {
          asked++;
          return const ApprovalAnswer(approved: true, rememberForSession: true);
        },
      );

      await loop.runTurn('dos comandos');

      expect(asked, 1);
      expect(log.events.whereType<ToolCallEvent>(), hasLength(2));
    });

    test('en modo readOnly se rechaza la escritura sin preguntar', () async {
      var asked = 0;
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                  id: 'c1', name: 'bash', arguments: <String, Object?>{}),
            ],
          ),
        ]),
        policy: ApprovalPolicy(level: ApprovalLevel.readOnly),
        approvalHandler: (final _) async {
          asked++;
          return const ApprovalAnswer(approved: true);
        },
      );

      expect(await loop.runTurn('x'), 'rejected');
      expect(asked, 0);
      expect(
        log.events.whereType<ToolResultEvent>().single.content,
        contains('solo lectura'),
      );
    });

    test('las herramientas de solo lectura no piden permiso', () async {
      registry.add(tool('read', requiresApproval: false));
      var asked = 0;
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[
          const LlmResponse(
            content: '',
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                  id: 'c1', name: 'read', arguments: <String, Object?>{}),
            ],
          ),
          const LlmResponse(content: 'ok'),
        ]),
        policy: ApprovalPolicy(level: ApprovalLevel.guarded),
        approvalHandler: (final _) async {
          asked++;
          return const ApprovalAnswer(approved: true);
        },
      );

      await loop.runTurn('lee');
      expect(asked, 0);
    });
  });

  group('AgentLoop — reintentos', () {
    test('reintenta un 429 y acaba bien', () async {
      final provider = FlakyProvider(
        failures: <LlmException>[
          const LlmException(LlmErrorKind.rateLimit, 'límite', statusCode: 429),
        ],
        result: const LlmResponse(content: 'por fin'),
      );
      final loop = makeLoop(
        provider,
        config: const AgentConfig(
          maxRetries: 2,
          retryBaseDelay: Duration(milliseconds: 1),
        ),
      );

      expect(await loop.runTurn('x'), 'completed');
      expect(provider.attempts, 2);
    });

    test('no reintenta un error de autenticación', () async {
      final provider = FlakyProvider(
        failures: <LlmException>[
          const LlmException(LlmErrorKind.auth, 'clave mala', statusCode: 401),
        ],
        result: const LlmResponse(content: 'no debería llegar'),
      );
      final loop = makeLoop(provider);
      final errors = <AgentErrorEvent>[];
      final sub = events.of<AgentErrorEvent>().listen(errors.add);

      final reason = await loop.runTurn('x');
      await Future<void>.delayed(Duration.zero);

      expect(reason, 'error');
      expect(provider.attempts, 1);
      expect(errors.single.message, contains('clave de API'));
      await sub.cancel();
    });

    test('agota los reintentos y devuelve error', () async {
      final provider = FlakyProvider(
        failures: List<LlmException>.generate(
          5,
          (final i) =>
              const LlmException(LlmErrorKind.server, 'boom', statusCode: 500),
        ),
        result: const LlmResponse(content: 'nunca'),
      );
      final loop = makeLoop(
        provider,
        config: const AgentConfig(
          maxRetries: 2,
          retryBaseDelay: Duration(milliseconds: 1),
        ),
      );

      expect(await loop.runTurn('x'), 'error');
      expect(provider.attempts, 3); // 1 intento + 2 reintentos
    });
  });

  group('AgentLoop — ciclo de vida', () {
    test('no permite dos turnos simultáneos', () async {
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[const LlmResponse(content: 'ok')]),
      );
      final first = loop.runTurn('uno');
      await expectLater(loop.runTurn('dos'), throwsStateError);
      await first;
    });

    test('cancel deja el turno en cancelled', () async {
      final loop = makeLoop(
        FakeProvider(<LlmResponse>[const LlmResponse(content: 'texto largo')]),
      );

      // Se cancela antes de que el modelo llegue a responder: el turno debe
      // cerrarse como cancelado y no quedarse colgado.
      final future = loop.runTurn('largo');
      await loop.cancel();

      expect(await future, 'cancelled');
      expect(log.events.whereType<TurnEndEvent>().single.reason, 'cancelled');
    });
  });

  group('PromptBuilder', () {
    test('incluye el entorno y las reglas de trabajo', () {
      final prompt = PromptBuilder.build(
        modeId: 'standard',
        tools: const <PluginTool>[],
      );
      expect(prompt, contains('/workspace'));
      expect(prompt, contains('apt'));
      expect(prompt, contains('todo_write'));
    });

    test('cada modo añade su sección y solo la suya', () {
      final minimal = PromptBuilder.build(
        modeId: 'minimal',
        tools: const <PluginTool>[],
      );
      expect(minimal, contains('Modo Minimal'));
      expect(minimal, isNot(contains('run_code')));

      final code = PromptBuilder.build(
        modeId: 'code',
        tools: const <PluginTool>[],
      );
      expect(code, contains('run_code'));

      final creator = PromptBuilder.build(
        modeId: 'creator',
        tools: const <PluginTool>[],
      );
      expect(creator, contains('cordis_inspect'));
    });

    test('incluye las instrucciones del proyecto cuando las hay', () {
      final prompt = PromptBuilder.build(
        modeId: 'standard',
        tools: const <PluginTool>[],
        projectInstructions: '--- AGENTS.md ---\nUsa `make test`.',
      );
      expect(prompt, contains('Instrucciones del proyecto'));
      expect(prompt, contains('make test'));

      final without = PromptBuilder.build(
        modeId: 'standard',
        tools: const <PluginTool>[],
      );
      expect(without, isNot(contains('Instrucciones del proyecto')));
    });

    test('lista las herramientas disponibles con su primera línea', () {
      final prompt = PromptBuilder.build(
        modeId: 'standard',
        tools: <PluginTool>[
          tool('read', requiresApproval: false),
          tool('bash', requiresApproval: true),
        ],
      );
      expect(prompt, contains('- read:'));
      expect(prompt, contains('- bash:'));
    });

    test('el resumen determinista menciona ficheros y fallos', () {
      const events = <SessionEvent>[
        UserMessageEvent(text: 'arregla el login'),
        ToolCallEvent(
          callId: 'c1',
          name: 'write',
          arguments: <String, Object?>{'path': '/workspace/login.dart'},
        ),
        ToolResultEvent(
          callId: 'c1',
          name: 'write',
          content: 'x',
          isError: true,
        ),
      ];

      final summary = PromptBuilder.deterministicSummary(events);

      expect(summary, contains('login.dart'));
      expect(summary, contains('1 ejecuciones fallidas'));
      expect(summary, contains('arregla el login'));
    });
  });

  group('ApprovalPolicy', () {
    test('guarded pregunta por escrituras y no por lecturas', () {
      final policy = ApprovalPolicy(level: ApprovalLevel.guarded);
      expect(policy.check(tool('read', requiresApproval: false)).needsUser,
          isFalse);
      expect(
          policy.check(tool('bash', requiresApproval: true)).needsUser, isTrue);
    });

    test('yolo permite todo', () {
      final policy = ApprovalPolicy(level: ApprovalLevel.yolo);
      expect(policy.check(tool('bash', requiresApproval: true)).decision,
          ApprovalDecision.allow);
    });

    test('una herramienta bloqueada se deniega en cualquier nivel', () {
      final policy = ApprovalPolicy(level: ApprovalLevel.yolo)
        ..denyTool('bash');
      expect(
          policy.check(tool('bash', requiresApproval: true)).isDenied, isTrue);
    });

    test('trust desactiva la pregunta solo para esa herramienta', () {
      final policy = ApprovalPolicy(level: ApprovalLevel.guarded)
        ..trust('bash');
      expect(policy.check(tool('bash', requiresApproval: true)).decision,
          ApprovalDecision.allow);
      expect(policy.check(tool('write', requiresApproval: true)).needsUser,
          isTrue);
      policy.forgetTrusted();
      expect(
          policy.check(tool('bash', requiresApproval: true)).needsUser, isTrue);
    });

    test('marca las herramientas de riesgo alto', () {
      expect(ApprovalPolicy.isHighRisk('bash'), isTrue);
      expect(ApprovalPolicy.isHighRisk('run_code'), isTrue);
      expect(ApprovalPolicy.isHighRisk('read'), isFalse);
    });
  });
}
