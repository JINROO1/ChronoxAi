import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/agent/agent_events.dart';
import '../../domain/agent/session_archive.dart';
import '../../domain/agent/session_log.dart';
import '../settings/settings_screen.dart';
import '../state/app_state.dart';

Future<void> showSessionsBrowser(final BuildContext context) async {
  final directory = await appSessionsDirectory();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ChronoxColors.backgroundElevated,
    builder: (final context) =>
        _SessionsBrowser(archive: SessionArchive(directory)),
  );
}

class _SessionsBrowser extends ConsumerStatefulWidget {
  const _SessionsBrowser({required this.archive});
  final SessionArchive archive;

  @override
  ConsumerState<_SessionsBrowser> createState() => _SessionsBrowserState();
}

class _SessionsBrowserState extends ConsumerState<_SessionsBrowser> {
  final _query = TextEditingController();
  late Future<List<ArchivedSession>> _sessions;

  @override
  void initState() {
    super.initState();
    _sessions = widget.archive.list();
    _query.addListener(_search);
  }

  void _search() {
    setState(() => _sessions = widget.archive.list(query: _query.text));
  }

  @override
  void dispose() {
    _query
      ..removeListener(_search)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(final BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ChronoxColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text('Sesiones y Trajectory',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              TextField(
                controller: _query,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar en títulos y conversaciones',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<ArchivedSession>>(
                  future: _sessions,
                  builder: (final context, final snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                          child: Text(
                              'No se pudieron leer las sesiones: ${snapshot.error}'));
                    }
                    final sessions = snapshot.data ?? const <ArchivedSession>[];
                    if (sessions.isEmpty) {
                      return const Center(
                          child: Text('No hay sesiones que coincidan.'));
                    }
                    return ListView.builder(
                      itemCount: sessions.length,
                      itemBuilder: (final context, final index) {
                        final session = sessions[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                              child: Icon(Icons.forum_outlined)),
                          title: Text(session.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${session.stats.turns} turnos · ${session.stats.totalTokens} tokens · '
                            '${session.updatedAt.toLocal()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Acciones del chat',
                            onSelected: (action) {
                              if (action == 'delete') _delete(session);
                            },
                            itemBuilder: (context) =>
                                const <PopupMenuEntry<String>>[
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Eliminar chat'),
                              ),
                            ],
                          ),
                          onTap: () => _showTrajectory(context, session),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(final ArchivedSession archived) async {
    final activeId = ref.read(sessionProvider)?.log.sessionId;
    if (activeId == archived.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se puede eliminar el chat activo.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar chat'),
        content: Text('¿Eliminar “${archived.title}” permanentemente?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await File(archived.path).delete();
      if (mounted) {
        setState(() => _sessions = widget.archive.list(query: _query.text));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo eliminar el chat: $error')),
        );
      }
    }
  }

  Future<void> _resume(final ArchivedSession session) async {
    Navigator.of(context).pop();
    await showNewSessionDialog(context, ref, sessionId: session.id);
  }

  Future<void> _fork(final ArchivedSession session) async {
    try {
      final dir = await appSessionsDirectory();
      final source = await SessionLog.open(dir, session.id);
      final newId = 'fork-${DateTime.now().microsecondsSinceEpoch}';
      final forked = await source.fork(dir, newId);
      await forked.close();
      await source.close();
      if (!mounted) return;
      Navigator.of(context).pop();
      await showNewSessionDialog(context, ref, sessionId: newId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo crear el fork: $error')),
      );
    }
  }

  Future<void> _showTrajectory(
    final BuildContext context,
    final ArchivedSession session,
  ) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: ChronoxColors.backgroundElevated,
        builder: (final context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: <Widget>[
                Text(session.title,
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                    '${session.stats.turns} turnos · ${session.stats.steps} pasos · '
                    '${session.stats.toolCalls} tools · ${session.stats.totalTokens} tokens'),
                Text('Tiempo modelo ${session.stats.modelTimeMs} ms · '
                    'herramientas ${session.stats.toolTimeMs} ms · '
                    'TTFT mediano ${session.stats.medianTimeToFirstTokenMs ?? '—'} ms'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: () => _resume(session),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Reanudar'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _fork(session),
                      icon: const Icon(Icons.fork_right),
                      label: const Text('Crear fork'),
                    ),
                  ],
                ),
                const Divider(height: 28),
                for (final event in session.events)
                  if (event is TurnStartEvent)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(event.userInput ?? 'Turno'),
                    )
                  else if (event is StepEndEvent)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.bolt_outlined),
                      title: Text('Paso ${event.stepIndex + 1} · '
                          '${event.inputTokens + event.outputTokens} tokens · '
                          '${event.durationMs} ms'),
                    )
                  else if (event is ToolCallEvent)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.build_outlined),
                      title: Text(event.name),
                      subtitle: Text(event.arguments.toString(),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
              ],
            ),
          ),
        ),
      );
}
