import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/runtime/runtime_process_journal.dart';
import '../state/app_state.dart';
import 'terminal_controller.dart';
import 'terminal_view.dart';

/// Terminal interactiva a pantalla completa. Cada pestaña conserva su propio
/// proceso PTY, por lo que pueden quedar shells/procesos abiertos en paralelo.
class MultiTerminalScreen extends ConsumerStatefulWidget {
  const MultiTerminalScreen({super.key});

  @override
  ConsumerState<MultiTerminalScreen> createState() =>
      _MultiTerminalScreenState();
}

class _MultiTerminalScreenState extends ConsumerState<MultiTerminalScreen> {
  final List<TerminalController> _terminals = <TerminalController>[];
  int _selected = 0;
  bool _opening = false;
  Timer? _elapsedTimer;
  RuntimeProcessJournal? _journal;

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (final _) {
      if (mounted && _terminals.isNotEmpty) setState(() {});
    });
    unawaited(_loadJournal());
    unawaited(_addTerminal());
  }

  Future<void> _loadJournal() async {
    try {
      final runtime = await ref.read(localRuntimeProvider.future);
      final journal = await RuntimeProcessJournal.open(runtime.paths.sessionsDir);
      if (mounted) setState(() => _journal = journal);
    } catch (_) {
      // Failure to read history must not prevent opening a fresh terminal.
    }
  }

  Future<void> _addTerminal() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final runtime = await ref.read(localRuntimeProvider.future);
      if (!mounted) return;
      final terminal = TerminalController(runtime: runtime);
      setState(() {
        _terminals.add(terminal);
        _selected = _terminals.length - 1;
      });
      await terminal.open();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo abrir la terminal: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _copyOutput() async {
    if (_terminals.isEmpty) return;
    final text = _terminals[_selected]
        .state
        .lines
        .map((final line) => line.text)
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Salida de terminal copiada.')),
      );
    }
  }

  Future<void> _closeSelected() async {
    if (_terminals.isEmpty) return;
    final terminal = _terminals.removeAt(_selected);
    await terminal.disposeSession();
    terminal.dispose();
    if (_terminals.isEmpty) {
      await _addTerminal();
    } else {
      setState(
          () => _selected = _selected.clamp(0, _terminals.length - 1).toInt());
    }
  }

  String _formatDuration(final Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    for (final terminal in _terminals) {
      unawaited(terminal.disposeSession());
      terminal.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _terminals.isEmpty ? null : _terminals[_selected];
    final journalRecords = _journal?.records.reversed.take(8).toList() ??
        const <RuntimeProcessRecord>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Copiar salida de terminal',
            onPressed: _terminals.isEmpty ? null : _copyOutput,
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: 'Nueva terminal',
            onPressed: _opening ? null : _addTerminal,
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            tooltip: 'Cerrar terminal actual',
            onPressed: _terminals.isEmpty ? null : _closeSelected,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_terminals.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView.separated(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                scrollDirection: Axis.horizontal,
                itemCount: _terminals.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) => ChoiceChip(
                  label: Text('Terminal ${index + 1}'),
                  selected: index == _selected,
                  onSelected: (_) => setState(() => _selected = index),
                  selectedColor: ChronoxColors.primary.withOpacity(.18),
                ),
              ),
            ),
          if (active != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: ChronoxColors.surface,
              child: Wrap(
                spacing: 14,
                runSpacing: 4,
                children: <Widget>[
                  Text('Estado: ${active.state.status.name}'),
                  Text('PID lógico: ${active.logicalProcessId ?? '—'}'),
                  Text(
                    'Tiempo: ${active.startedAt == null ? '—' : _formatDuration((active.exitedAt ?? DateTime.now()).difference(active.startedAt!))}',
                  ),
                  Text('Salida total: ${active.outputBytesProduced} bytes'),
                  Text(
                    'Scrollback: ${active.retainedLines}/${active.scrollbackLimitLines} líneas',
                  ),
                  if (active.state.exitCode != null)
                    Text('Código de salida: ${active.state.exitCode}'),
                ],
              ),
            ),
          if (journalRecords.isNotEmpty)
            ExpansionTile(
              title: const Text('Historial de procesos'),
              subtitle: const Text(
                'Solo metadatos; las sesiones muertas no se reanudan.',
              ),
              children: <Widget>[
                for (final record in journalRecords)
                  ListTile(
                    dense: true,
                    title: Text('${record.title} · ${record.state.name}'),
                    subtitle: Text(
                      '${record.startedAt.toLocal()} · ${record.outputBytes} bytes'
                      '${record.exitCode == null ? '' : ' · código ${record.exitCode}'}'
                      '${record.state == RuntimeProcessState.orphaned ? ' · proceso perdido al reiniciar' : ''}',
                    ),
                  ),
              ],
            ),
          const Divider(height: 1),
          Expanded(
            child: active == null
                ? const Center(child: CircularProgressIndicator())
                : TerminalView(
                    key: ValueKey<TerminalController>(active),
                    controller: active,
                  ),
          ),
        ],
      ),
    );
  }
}
