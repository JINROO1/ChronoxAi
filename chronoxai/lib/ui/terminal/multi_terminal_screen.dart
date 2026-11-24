import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../state/app_state.dart';
import 'terminal_controller.dart';
import 'terminal_view.dart';

/// Terminal interactiva a pantalla completa. Cada pestaña conserva su propio
/// proceso PTY, por lo que pueden quedar shells/procesos abiertos en paralelo.
class MultiTerminalScreen extends ConsumerStatefulWidget {
  const MultiTerminalScreen({super.key});

  @override
  ConsumerState<MultiTerminalScreen> createState() => _MultiTerminalScreenState();
}

class _MultiTerminalScreenState extends ConsumerState<MultiTerminalScreen> {
  final List<TerminalController> _terminals = <TerminalController>[];
  int _selected = 0;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(_addTerminal());
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

  Future<void> _closeSelected() async {
    if (_terminals.isEmpty) return;
    final terminal = _terminals.removeAt(_selected);
    await terminal.disposeSession();
    terminal.dispose();
    if (_terminals.isEmpty) {
      await _addTerminal();
    } else {
      setState(() => _selected =
          _selected.clamp(0, _terminals.length - 1).toInt());
    }
  }

  @override
  void dispose() {
    for (final terminal in _terminals) {
      unawaited(terminal.disposeSession());
      terminal.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _terminals.isEmpty ? null : _terminals[_selected];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: <Widget>[
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
