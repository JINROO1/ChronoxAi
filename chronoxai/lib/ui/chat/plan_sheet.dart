import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/agent/agent_loop.dart';

/// Presenta el plan del agente y espera su aprobación.
///
/// Es el plan mode de dsh en la UI: el motor se detiene en `exit_plan_mode`
/// hasta que el usuario decide. Cerrar la hoja sin decidir equivale a rechazar,
/// igual que en la hoja de aprobación de herramientas.
Future<ApprovalAnswer> showPlanSheet(
  final BuildContext context, {
  required final String plan,
}) async {
  final answer = await showModalBottomSheet<ApprovalAnswer>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    builder: (final context) => _PlanSheet(plan: plan),
  );

  return answer ?? const ApprovalAnswer.denied();
}

class _PlanSheet extends StatelessWidget {
  const _PlanSheet({required this.plan});

  final String plan;

  @override
  Widget build(final BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        decoration: BoxDecoration(
          color: ChronoxColors.backgroundElevated,
          borderRadius: BorderRadius.circular(ChronoxRadius.lg),
          border: Border.all(color: ChronoxColors.accent.withOpacity(0.35)),
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
                        color: ChronoxColors.accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                      ),
                      child: const Icon(
                        Icons.map_outlined,
                        size: 18,
                        color: ChronoxColors.accent,
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Plan del agente',
                            style: TextStyle(
                              color: ChronoxColors.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Revísalo antes de que empiece a actuar',
                            style: TextStyle(
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
                Flexible(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ChronoxColors.codeBackground,
                      borderRadius: BorderRadius.circular(ChronoxRadius.sm),
                      border: Border.all(color: ChronoxColors.border),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        plan.isEmpty ? '(plan vacío)' : plan,
                        style: const TextStyle(
                          color: ChronoxColors.textPrimary,
                          fontSize: 12.5,
                          height: 1.55,
                          fontFamily: ChronoxTheme.monoFamily,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
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
                          const ApprovalAnswer(approved: true),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: ChronoxColors.accent,
                          foregroundColor: const Color(0xFF00120D),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: const RoundedRectangleBorder(
                            borderRadius: ChronoxRadius.card,
                          ),
                        ),
                        child: const Text('Aprobar plan'),
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
