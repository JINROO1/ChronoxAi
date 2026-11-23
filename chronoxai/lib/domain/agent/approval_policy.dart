import '../plugins/plugin_api.dart';

/// Niveles de acceso, tomados de DeepSeek Harness.
///
/// dsh expone tres tiers de política de workspace; el nombre importa menos que
/// el hecho de que sean **explícitos y visibles** antes de que el agente actúe.
enum ApprovalLevel {
  /// Solo lectura: inspeccionar ficheros y listar. Nada de escrituras ni shell.
  readOnly,

  /// Escrituras y comandos piden confirmación, con vista previa (diff/comando).
  /// Es el valor por defecto: el agente propone, el usuario decide.
  guarded,

  /// Todo aprobado automáticamente. Solo tiene sentido dentro de un contenedor
  /// que ya está aislado (y aun así, el usuario debe saber lo que hace).
  yolo;

  String get label => switch (this) {
    ApprovalLevel.readOnly => 'Solo lectura',
    ApprovalLevel.guarded => 'Con confirmación',
    ApprovalLevel.yolo => 'Sin confirmación',
  };

  String get description => switch (this) {
    ApprovalLevel.readOnly =>
      'El agente puede leer ficheros y listar, pero no modificar nada ni '
          'ejecutar comandos.',
    ApprovalLevel.guarded =>
      'Cada escritura y cada comando se muestran antes de ejecutarse. '
          'Recomendado.',
    ApprovalLevel.yolo =>
      'Todo se ejecuta sin preguntar. Úsalo solo si confías por completo en la '
          'tarea y en el modelo.',
  };
}

/// Qué debe hacer el motor ante una herramienta concreta.
enum ApprovalDecision {
  /// Ejecutar sin preguntar.
  allow,

  /// Preguntar al usuario.
  ask,

  /// Rechazar y devolver el motivo al modelo.
  deny,
}

/// Resultado de consultar la política.
class ApprovalOutcome {
  const ApprovalOutcome(this.decision, {this.reason});

  const ApprovalOutcome.allow()
    : decision = ApprovalDecision.allow,
      reason = null;

  const ApprovalOutcome.ask()
    : decision = ApprovalDecision.ask,
      reason = null;

  const ApprovalOutcome.deny(this.reason)
    : decision = ApprovalDecision.deny;

  final ApprovalDecision decision;
  final String? reason;

  bool get isDenied => decision == ApprovalDecision.deny;
  bool get needsUser => decision == ApprovalDecision.ask;
}

/// Decide si una herramienta puede ejecutarse.
///
/// La política es **por herramienta y por nivel**, no por texto del comando:
/// analizar la peligrosidad de una cadena de shell es imposible de hacer bien,
/// y un falso negativo aquí significa ejecutar algo destructivo. Se delega en
/// el usuario, que ve el comando exacto.
class ApprovalPolicy {
  ApprovalPolicy({
    this.level = ApprovalLevel.guarded,
    final Set<String>? trustedTools,
    final Set<String>? deniedTools,
  }) : _trusted = trustedTools ?? <String>{},
       _denied = deniedTools ?? <String>{};

  ApprovalLevel level;

  /// Herramientas que el usuario marcó "no volver a preguntar".
  final Set<String> _trusted;

  /// Herramientas bloqueadas explícitamente.
  final Set<String> _denied;

  /// Herramientas que nunca modifican estado y por tanto no requieren permiso.
  static const Set<String> readOnlyTools = <String>{
    'read',
    'glob',
    'grep',
    'terminal_read',
    'terminal_list',
    'disk_usage',
    'web_fetch',
    'cordis_inspect',
    'todo_write',
    'exit_plan_mode',
    'str_replace_editor_read',
  };

  /// Herramientas que pueden destruir datos o salir del workspace.
  static const Set<String> highRiskTools = <String>{
    'bash',
    'terminal_send',
    'terminal_close',
    'apply_patch',
    'run_code',
    'plugin_manager',
    'subagent',
  };

  /// Consulta la política para una herramienta.
  ///
  /// [tool] se usa para leer `requiresApproval`, que el autor del plugin declaró.
  ApprovalOutcome check(final PluginTool tool) {
    if (_denied.contains(tool.name)) {
      return ApprovalOutcome.deny(
        'La herramienta "${tool.name}" está bloqueada en Ajustes.',
      );
    }

    switch (level) {
      case ApprovalLevel.readOnly:
        // En solo lectura, todo lo que no esté en la lista blanca se rechaza.
        if (readOnlyTools.contains(tool.name) || !tool.requiresApproval) {
          return const ApprovalOutcome.allow();
        }
        return ApprovalOutcome.deny(
          'Estás en modo solo lectura: "${tool.name}" modifica el sistema. '
          'Cambia el nivel de acceso en Ajustes si quieres permitirlo.',
        );

      case ApprovalLevel.yolo:
        return const ApprovalOutcome.allow();

      case ApprovalLevel.guarded:
        if (!tool.requiresApproval || readOnlyTools.contains(tool.name)) {
          return const ApprovalOutcome.allow();
        }
        if (_trusted.contains(tool.name)) {
          return const ApprovalOutcome.allow();
        }
        return const ApprovalOutcome.ask();
    }
  }

  /// El usuario aprobó y pidió no volver a preguntar por esta herramienta.
  void trust(final String toolName) => _trusted.add(toolName);

  /// Olvida las aprobaciones dadas en esta sesión.
  void forgetTrusted() => _trusted.clear();

  /// Bloquea una herramienta hasta nuevo aviso.
  void denyTool(final String toolName) => _denied.add(toolName);

  /// Desbloquea una herramienta.
  void allowTool(final String toolName) => _denied.remove(toolName);

  Set<String> get trustedTools => Set<String>.unmodifiable(_trusted);
  Set<String> get deniedTools => Set<String>.unmodifiable(_denied);

  /// `true` si la herramienta puede modificar el sistema.
  static bool isHighRisk(final String toolName) =>
      highRiskTools.contains(toolName);
}
