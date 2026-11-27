import 'dart:async';

import 'package:flutter/material.dart';
import '../../data/runtime/pty_session.dart';

class BackgroundJobsScreen extends StatefulWidget {
  const BackgroundJobsScreen({super.key});

  @override
  State<BackgroundJobsScreen> createState() => _BackgroundJobsScreenState();
}

class _BackgroundJobsScreenState extends State<BackgroundJobsScreen> {
  List<Map<String, Object?>> _sessions = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final sessions = PtySession.listActive();
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _close(final int id) async {
    await PtySession.closeActive(id);
    await _refresh();
  }

  @override
  Widget build(final BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Trabajos en segundo plano')),
        body: _sessions.isEmpty
            ? const Center(child: Text('No hay terminales activas.'))
            : RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  children: _sessions.map((final session) {
                    final id = session['id']! as int;
                    return ListTile(
                      leading: const Icon(Icons.terminal_rounded),
                      title: Text('Terminal #$id'),
                      subtitle: Text(session['command'] as String? ?? 'Activa'),
                      trailing: IconButton(
                        tooltip: 'Cerrar terminal',
                        onPressed: () => _close(id),
                        icon: const Icon(Icons.stop_circle_outlined),
                      ),
                    );
                  }).toList(),
                ),
              ),
      );
}
