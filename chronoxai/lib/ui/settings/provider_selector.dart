import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../state/app_state.dart';

String providerLabel(final ProviderKind kind) => switch (kind) {
      ProviderKind.openAiCompatible => 'OpenAI compatible',
      ProviderKind.anthropic => 'Anthropic Messages API',
      ProviderKind.gemini => 'Google Gemini API',
      ProviderKind.ollama => 'Ollama local (sin API key)',
    };

Future<void> selectProvider(
  final BuildContext context,
  final WidgetRef ref,
  final ProviderSettings current,
) async {
  final selected = await showModalBottomSheet<ProviderKind>(
    context: context,
    backgroundColor: ChronoxColors.backgroundElevated,
    builder: (final context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final kind in ProviderKind.values)
            ListTile(
              leading: Icon(kind == current.kind
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(providerLabel(kind)),
              onTap: () => Navigator.pop(context, kind),
            ),
        ],
      ),
    ),
  );
  if (selected == null) return;
  final defaults = switch (selected) {
    ProviderKind.openAiCompatible => (
        'https://api.deepseek.com/v1',
        'deepseek-chat'
      ),
    ProviderKind.anthropic => (
        'https://api.anthropic.com',
        'claude-3-7-sonnet-latest'
      ),
    ProviderKind.gemini => (
        'https://generativelanguage.googleapis.com',
        'gemini-2.5-flash'
      ),
    ProviderKind.ollama => ('http://127.0.0.1:11434/v1', 'llama3.2'),
  };
  ref.read(providerSettingsProvider.notifier).state = current.copyWith(
    kind: selected,
    baseUrl: defaults.$1,
    model: defaults.$2,
  );
}
