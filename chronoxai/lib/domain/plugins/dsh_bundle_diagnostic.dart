import 'dart:convert';

/// Capability report for a DeepSeek Harness bundle. This is intentionally a
/// preflight analyzer, not an executor: Cordis plugins are Node.js programs and
/// must never be treated as directly portable to ChronoxAI.
class DshBundleDiagnostic {
  const DshBundleDiagnostic({
    required this.bundleName,
    required this.hasCordisPatch,
    required this.hasNodePlugins,
    required this.hasUiContribution,
    required this.hasServiceContribution,
  });

  final String bundleName;
  final bool hasCordisPatch;
  final bool hasNodePlugins;
  final bool hasUiContribution;
  final bool hasServiceContribution;

  bool get canImportAsMcp => hasNodePlugins && !hasCordisPatch;

  List<String> get supported => <String>[
        if (hasNodePlugins)
          'Node plugin: posible integración solo si expone un servidor MCP stdio/HTTP.',
        if (!hasCordisPatch) 'No se detectó cordis.patch.yml.',
      ];

  List<String> get unsupported => <String>[
        if (hasCordisPatch)
          'cordis.patch.yml modifica el runtime Cordis y no se aplica en ChronoxAI.',
        if (hasUiContribution)
          'La contribución de interfaz Cordis no se puede montar como UI de ChronoxAI.',
        if (hasServiceContribution)
          'Los servicios/eventos Cordis requieren una adaptación explícita.',
        if (hasNodePlugins && !canImportAsMcp)
          'Los plugins Node arbitrarios no se ejecutan directamente; solo MCP es compatible.',
      ];

  Map<String, Object?> toJson() => <String, Object?>{
        'bundle': bundleName,
        'classification':
            canImportAsMcp ? 'mcp_candidate' : 'manual_port_required',
        'supported': supported,
        'unsupported': unsupported,
        'actions': <String>[
          if (canImportAsMcp)
            'Revise el código y configure manualmente el endpoint MCP como servidor permitido.',
          'No se instaló ni ejecutó código del bundle.',
        ],
      };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Classifies a bundle from an already inspected file listing and optional
  /// package metadata. It does not extract archives or run package scripts.
  static DshBundleDiagnostic inspect({
    required String bundleName,
    required Iterable<String> files,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final normalized = files
        .map((final path) => path.replaceAll('\\', '/').toLowerCase())
        .toList();
    final metadataText = jsonEncode(metadata).toLowerCase();
    final hasCordisPatch =
        normalized.any((final path) => path.endsWith('cordis.patch.yml'));
    final hasNodePlugins = normalized.any((final path) =>
        path.endsWith('package.json') ||
        path.contains('/plugins/') && path.endsWith('.js'));
    final hasUi = metadataText.contains('ui') ||
        normalized.any((final path) =>
            path.contains('/ui/') ||
            path.endsWith('.tsx') ||
            path.endsWith('.vue'));
    final hasService = metadataText.contains('service') ||
        metadataText.contains('inject') ||
        metadataText.contains('provider');
    return DshBundleDiagnostic(
      bundleName: bundleName,
      hasCordisPatch: hasCordisPatch,
      hasNodePlugins: hasNodePlugins,
      hasUiContribution: hasUi,
      hasServiceContribution: hasService,
    );
  }
}
