import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/agent/agent_loop.dart';

/// Pregunta al usuario antes de ejecutar una herramienta.
///
/// Es la única barrera entre el modelo y el dispositivo, así que está pensada
/// para decidir rápido: qué se va a ejecutar, con qué alcance, y dos botones.
/// El botón peligroso nunca es el que está bajo el pulgar por defecto.
Future<ApprovalAnswer> showApprovalSheet(
  final BuildContext context, {
  required final ApprovalRequest request,
  required final bool isHighRisk,
}) async {
  final answer = await showModalBottomSheet<ApprovalAnswer>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    builder: (final context) => _ApprovalSheet(
      request: request,
      isHighRisk: isHighRisk,
    ),
  );

  // Cerrar la hoja sin decidir equivale a rechazar: es lo seguro y además
  // coherente con el resto del motor, que nunca ejecuta sin un "sí" explícito.
  return answer ?? const ApprovalAnswer.denied();
}

class _ApprovalSheet extends StatefulWidget {
  const _ApprovalSheet({required this.request, required this.isHighRisk});

  final ApprovalRequest request;
  final bool isHighRisk;

  @override
  State<_ApprovalSheet> createState() => _ApprovalSheetState();
}

class _ApprovalSheetState extends State<_ApprovalSheet> {
  bool _remember = false;

  @override
  Widget build(final BuildContext context) {
    final accent =
        widget.isHighRisk ? ChronoxColors.warning : ChronoxColors.primary;

    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: ChronoxColors.backgroundElevated,
          borderRadius: BorderRadius.circular(ChronoxRadius.lg),
          border: Border.all(color: accent.withOpacity(0.35)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 30,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                      ),
                      child: Icon(
                        widget.isHighRisk
                            ? Icons.warning_amber_rounded
                            : Icons.shield_outlined,
                        size: 18,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'Permiso necesario',
                            style: TextStyle(
                              color: ChronoxColors.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'El agente quiere usar ${widget.request.toolName}',
                            style: const TextStyle(
                              color: ChronoxColors.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _CommandPreview(
                  preview: widget.request.preview,
                  diff: widget.request.diff,
                ),
                if (widget.isHighRisk) ...<Widget>[
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      const Icon(
                        Icons.info_outline_rounded,
                        size: 14,
                        color: ChronoxColors.warning,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'Esta herramienta puede modificar ficheros o ejecutar '
                          'cualquier comando dentro del contenedor.',
                          style: TextStyle(
                            color: ChronoxColors.warning.withOpacity(0.9),
                            fontSize: 11.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                InkWell(
                  onTap: () => setState(() => _remember = !_remember),
                  borderRadius: ChronoxRadius.sm,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: _remember,
                            onChanged: (final v) =>
                                setState(() => _remember = v ?? false),
                            activeColor: accent,
                            side: const BorderSide(
                              color: ChronoxColors.borderGlow,
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'No volver a preguntar en esta sesión',
                            style: TextStyle(
                              color: ChronoxColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(
                          const ApprovalAnswer.denied(),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: ChronoxColors.textSecondary,
                          side: const BorderSide(color: ChronoxColors.border),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: const RoundedRectangleBorder(
                            borderRadius: ChronoxRadius.card,
                          ),
                        ),
                        child: const Text('Rechazar'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(
                          ApprovalAnswer(
                            approved: true,
                            rememberForSession: _remember,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: const Color(0xFF00120D),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: const RoundedRectangleBorder(
                            borderRadius: ChronoxRadius.card,
                          ),
                        ),
                        child: const Text('Permitir'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Vista previa de lo que se va a ejecutar: comando o diff.
class _CommandPreview extends StatelessWidget {
  const _CommandPreview({required this.preview, this.diff});

  final String preview;
  final String? diff;

  @override
  Widget build(final BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ChronoxColors.codeBackground,
        borderRadius: ChronoxRadius.sm,
        border: Border.all(color: ChronoxColors.border),
      ),
      child: SingleChildScrollView(
        child: diff == null
            ? SelectableText(
                preview,
                style: const TextStyle(
                  color: ChronoxColors.textPrimary,
                  fontSize: 12.5,
                  height: 1.55,
                  fontFamily: ChronoxTheme.monoFamily,
                ),
              )
            : _DiffView(diff: diff!),
      ),
    );
  }
}

/// Diff con las líneas añadidas y quitadas resaltadas.
///
/// Se pinta línea a línea en lugar de un único `TextSpan`: cada línea necesita su
/// propio fondo, que es lo que hace legible un diff.
class _DiffView extends StatelessWidget {
  const _DiffView({required this.diff});

  final String diff;

  @override
  Widget build(final BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final line in diff.split('\n'))
          Container(
            color: line.startsWith('+')
                ? ChronoxColors.codeAddition
                : line.startsWith('-')
                ? ChronoxColors.codeDeletion
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              line.isEmpty ? ' ' : line,
              style: TextStyle(
                color: line.startsWith('+')
                    ? ChronoxColors.success
                    : line.startsWith('-')
                    ? ChronoxColors.danger
                    : ChronoxColors.textSecondary,
                fontSize: 12.5,
                height: 1.4,
                fontFamily: ChronoxTheme.monoFamily,
              ),
            ),
          ),
      ],
    );
  }
}
