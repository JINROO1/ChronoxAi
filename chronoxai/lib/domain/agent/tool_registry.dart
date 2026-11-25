import 'dart:convert';

import '../plugins/plugin_api.dart';
import 'tool_diagnostics.dart';

/// Registro de herramientas con ámbito y validación.
///
/// Equivalente a `ctx.tools` de dsh: un registro **con ámbito** (cada agente o
/// modo puede ver un subconjunto) y un pipeline de ejecución con guards.
class ToolRegistry {
  final Map<String, PluginTool> _tools = <String, PluginTool>{};

  /// Nombres registrados, ordenados para que el prompt sea determinista.
  Iterable<String> get names => _tools.keys.toList()..sort();

  Iterable<PluginTool> get all => names.map((final n) => _tools[n]!);

  int get length => _tools.length;

  bool contains(final String name) => _tools.containsKey(name);

  PluginTool? operator [](final String name) => _tools[name];

  /// Registra una herramienta. Lanza si el nombre ya existe: dos herramientas
  /// con el mismo nombre harían que el modelo invocara una arbitrariamente.
  void add(final PluginTool tool) {
    if (_tools.containsKey(tool.name)) {
      throw StateError(
        'Ya existe una herramienta llamada "${tool.name}". '
        'Los nombres deben ser únicos en todo el runtime.',
      );
    }
    _tools[tool.name] = tool;
  }

  /// Elimina una herramienta (lo usa el `Disposable` de los plugins).
  void remove(final String name) => _tools.remove(name);

  /// Esquemas en formato `tools` de la API de OpenAI.
  List<Map<String, Object?>> toOpenAiSchemas({final Set<String>? only}) {
    return all
        .where((final t) => only == null || only.contains(t.name))
        .map(
          (final t) => <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{
              'name': t.name,
              'description': t.description,
              'parameters': t.inputSchema,
            },
          },
        )
        .toList();
  }

  /// Valida los argumentos contra el esquema y ejecuta.
  ///
  /// La validación es deliberadamente estructural y no un JSON-Schema completo:
  /// cubre `required`, tipos primitivos, `enum` y objetos anidados, que es lo
  /// que necesitan las herramientas del agente. Un esquema inválido del modelo
  /// se convierte en un mensaje de error legible que el modelo puede corregir.
  Future<ToolOutcome> execute(
    final String name,
    final Map<String, Object?> arguments,
  ) async {
    final tool = _tools[name];
    if (tool == null) {
      return ToolOutcome.error(
        'La herramienta "$name" no existe. Disponibles: ${names.join(', ')}.',
        errorCategory: ToolFailureKind.toolError.jsonName,
        recoveryHint:
            'Usa una herramienta registrada en el catálogo disponible.',
      );
    }

    final problems = validateArguments(tool.inputSchema, arguments);
    if (problems.isNotEmpty) {
      return ToolOutcome.error(
        'Argumentos inválidos para "$name": ${problems.join('; ')}. '
        'Corrige y vuelve a intentar.',
        errorCategory: ToolFailureKind.invalidArguments.jsonName,
        recoveryHint: const ToolDiagnostic(
          kind: ToolFailureKind.invalidArguments,
          recoveryHint:
              'Compara los argumentos con el esquema y corrige campos, tipos o '
              'valores; no repitas la misma llamada.',
        ).recoveryHint,
      );
    }

    try {
      return await tool.execute(arguments);
    } catch (error) {
      final diagnostic = ToolDiagnostic.fromException(
        error,
        toolName: name,
      );
      return ToolOutcome.error(
        'Error ejecutando "$name": $error',
        errorCategory: diagnostic.kind.jsonName,
        recoveryHint: diagnostic.recoveryHint,
      );
    }
  }

  /// Valida [arguments] contra un subconjunto de JSON Schema.
  ///
  /// Devuelve la lista de problemas; vacía si es válido.
  static List<String> validateArguments(
    final Map<String, Object?> schema,
    final Map<String, Object?> arguments,
  ) {
    final problems = <String>[];

    final required =
        (schema['required'] as List<Object?>?) ?? const <Object?>[];
    for (final key in required.cast<String>()) {
      if (!arguments.containsKey(key) || arguments[key] == null) {
        problems.add('falta el campo requerido "$key"');
      }
    }

    final properties = (schema['properties'] as Map<String, Object?>?) ??
        const <String, Object?>{};

    for (final entry in arguments.entries) {
      final spec = properties[entry.key];
      if (spec == null) {
        // Campo no declarado: se ignora en lugar de fallar, porque los modelos
        // a veces añaden metadatos inofensivos.
        continue;
      }
      if (spec is! Map<String, Object?>) continue;

      final type = spec['type'] as String?;
      final value = entry.value;
      if (value == null) continue;

      final typeProblem = _checkType(entry.key, type, value);
      if (typeProblem != null) {
        problems.add(typeProblem);
        continue;
      }

      final allowed = (spec['enum'] as List<Object?>?)?.cast<Object?>();
      if (allowed != null && !allowed.contains(value)) {
        problems.add(
          '"${entry.key}" debe ser uno de: '
          '${allowed.map((final a) => jsonEncode(a)).join(', ')}',
        );
      }

      if (type == 'object' && value is Map<String, Object?>) {
        final nested = spec;
        problems.addAll(
          validateArguments(nested, value).map((final p) => '${entry.key}.$p'),
        );
      }
    }

    return problems;
  }

  static String? _checkType(
    final String key,
    final String? type,
    final Object value,
  ) {
    final ok = switch (type) {
      'string' => value is String,
      'integer' => value is int,
      'number' => value is num,
      'boolean' => value is bool,
      'array' => value is List<Object?>,
      'object' => value is Map<String, Object?>,
      null => true, // sin tipo declarado: se acepta
      _ => true,
    };
    if (ok) return null;
    return '"$key" debe ser de tipo $type (recibido ${value.runtimeType})';
  }
}
