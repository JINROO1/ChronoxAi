import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OfflineLicensesScreen extends StatelessWidget {
  const OfflineLicensesScreen({super.key});

  static const _assets = <String, String>{
    'Atribuciones y revisiones': 'assets/licenses/THIRD_PARTY_NOTICES.md',
    'Apache License 2.0': 'assets/licenses/Apache-2.0.txt',
    'llama.cpp — MIT License': 'assets/licenses/llama.cpp-MIT.txt',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Licencias offline')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            for (final entry in _assets.entries) ...<Widget>[
              Text(entry.key, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              FutureBuilder<String>(
                future: rootBundle.loadString(entry.value),
                builder: (final context, final snapshot) {
                  if (snapshot.hasError) {
                    return Text(
                      'No se pudo leer el aviso: ${snapshot.error}',
                      style: const TextStyle(color: ChronoxColors.danger),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const LinearProgressIndicator();
                  }
                  return SelectableText(
                    snapshot.data!,
                    style: const TextStyle(
                      color: ChronoxColors.textSecondary,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      );
}
