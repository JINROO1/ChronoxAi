import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'chat/chat_screen.dart';
import 'plugins/plugins_screen.dart';
import 'settings/settings_screen.dart';
import 'terminal/multi_terminal_screen.dart';

/// Contenedor principal: barra inferior con las tres áreas de la app.
///
/// Se usa `IndexedStack` para que la conversación conserve su scroll y su estado
/// al cambiar de pestaña: volver del terminal a la sesión no debe perder el hilo.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination(
      label: 'Sesión',
      icon: Icons.auto_awesome_outlined,
      activeIcon: Icons.auto_awesome,
    ),
    _Destination(
      label: 'Plugins',
      icon: Icons.extension_outlined,
      activeIcon: Icons.extension,
    ),
    _Destination(
      label: 'Ajustes',
      icon: Icons.tune_outlined,
      activeIcon: Icons.tune,
    ),
    _Destination(
      label: 'Terminal',
      icon: Icons.terminal_outlined,
      activeIcon: Icons.terminal,
    ),
  ];

  void _selectDestination(int index) {
    if (index == 3) {
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const MultiTerminalScreen(),
        ),
      );
      return;
    }
    setState(() => _index = index);
  }

  @override
  Widget build(final BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          ChatScreen(),
          PluginsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: _ChronoxNavBar(
        index: _index,
        destinations: _destinations,
        onSelected: _selectDestination,
      ),
    );
  }
}

class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// Barra propia en lugar de `NavigationBar`: la de Material no permite el fondo
/// translúcido con borde superior fino que necesita la estética de la app.
class _ChronoxNavBar extends StatelessWidget {
  const _ChronoxNavBar({
    required this.index,
    required this.destinations,
    required this.onSelected,
  });

  final int index;
  final List<_Destination> destinations;
  final ValueChanged<int> onSelected;

  @override
  Widget build(final BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(14, 8, 14, 8 + bottomInset),
      decoration: const BoxDecoration(
        color: ChronoxColors.backgroundElevated,
        border: Border(top: BorderSide(color: ChronoxColors.border)),
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < destinations.length; i++)
            Expanded(
              child: _NavItem(
                destination: destinations[i],
                selected: i == index,
                onTap: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(final BuildContext context) {
    final color = selected ? ChronoxColors.primary : ChronoxColors.textMuted;

    return Semantics(
      selected: selected,
      button: true,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: ChronoxRadius.card,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? ChronoxColors.primary.withOpacity(0.10)
                : Colors.transparent,
            borderRadius: ChronoxRadius.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                selected ? destination.activeIcon : destination.icon,
                size: 21,
                color: color,
              ),
              const SizedBox(height: 4),
              Text(
                destination.label,
                style: TextStyle(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
