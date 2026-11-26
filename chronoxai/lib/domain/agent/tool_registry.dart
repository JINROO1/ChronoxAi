import 'dart:convert';

import '../plugins/plugin_api.dart';
import 'tool_diagnostics.dart';

/// Registro de herramientas con ámbito y validación.
///
/// Equivalente a `ctx.tools` de dsh: un registro **con ámbito** (cada agente o
/// modo puede ver un subconjunto) y un pipeline de ejecución con guards.
class ToolRegistry {
  static Map<String, Object?> _normalizeSchema(Map<String, Object?> schema) {
    final normalized = <String, Object?>{};
    for (final entry in schema.entries) {
      final value = entry.value;
      if (entry.key == 'properties' && value is Map) {
        normalized[entry.key] = <String, Object?>{
          for (final property in value.entries)
            property.key.toString(): _normalizeProperty(property.value),
        };
      } else if (entry.key == 'items' && value is Map) {
        normalized[entry.key] = _normalizeSchema(
          value.map((final key, final item) => MapEntry(key.toString(), item)),
        );
      } else if ((entry.key == 'anyOf' ||
              entry.key == 'oneOf' ||
              entry.key == 'allOf') &&
          value is List) {
        normalized[entry.key] =
            value.map(_normalizeProperty).toList(growable: false);
      } else {
        normalized[entry.key] = value;
      }
    }
    return normalized;
  }

  static Object? _normalizeProperty(Object? property) {
    if (property is Map) {
      return _normalizeSchema(
        property
            .map((final key, final value) => MapEntry(key.toString(), value)),
      );
    }
    if (property is String) {
      const supported = <String>{
        'string',
        'number',
        'integer',
        'boolean',
        'object',
        'array'
      };
      return <String, Object?>{
        'type': supported.contains(property) ? property : 'string'
      };
    }
    // Unsupported/non-object declarations are made permissive instead of
    // sending a malformed tool catalog and failing the whole provider request.
    return <String, Object?>{'type': 'string'};
  }

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
              // MCP y plugins externos pueden publicar shorthand inválidos
              // (p. ej. `properties: {"query": "string"}`). La API espera un
              // objeto JSON Schema por propiedad; normalizar evita un HTTP 400
              // que abortaría todo el turno aunque el resto de herramientas sea
              // válido.
              'parameters': _normalizeSchema(t.inputSchema),
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
  ) =>
      _validateObject(schema, arguments, '');

  static List<String> _validateObject(
    Map<String, Object?> schema,
    Map<String, Object?> arguments,
    String path,
  ) {
    final problems = <String>[];
    final required = schema['required'];
    if (required is List) {
      for (final item in required) {
        if (item is! String) continue;
        if (!arguments.containsKey(item) || arguments[item] == null) {
          problems.add('${path.isEmpty ? '' : '$path.'}falta el campo requerido "$item"');
        }
      }
    }

    final rawProperties = schema['properties'];
    final properties = rawProperties is Map
        ? rawProperties.map((final key, final value) =>
            MapEntry(key.toString(), value))
        : const <String, Object?>{};
    for (final entry in arguments.entries) {
      final childPath = path.isEmpty ? entry.key : '$path.${entry.key}';
      final rawSpec = properties[entry.key];
      if (rawSpec == null) {
        if (schema['additionalProperties'] == false) {
          problems.add('$childPath no está permitido');
        }
        continue;
      }
      if (rawSpec is! Map) continue;
      final spec = rawSpec.map(
        (final key, final value) => MapEntry(key.toString(), value),
      );
      problems.addAll(_validateValue(childPath, spec, entry.value));
    }
    return problems;
  }

  static List<String> _validateValue(
    String path,
    Map<String, Object?> schema,
    Object? value,
  ) {
    if (value == null) return const <String>[];
    final type = schema['type'] as String?;
    final typeProblem = _checkType(path, type, value);
    if (typeProblem != null) return <String>[typeProblem];

    final problems = <String>[];
    final allowed = schema['enum'];
    if (allowed is List && !allowed.contains(value)) {
      problems.add(
        '"$path" debe ser uno de: '
        '${allowed.map((final item) => jsonEncode(item)).join(', ')}',
      );
    }

    if (value is String) {
      final minLength = schema['minLength'];
      final maxLength = schema['maxLength'];
      if (minLength is int && value.length < minLength) {
        problems.add('"$path" debe tener al menos $minLength caracteres');
      }
      if (maxLength is int && value.length > maxLength) {
        problems.add('"$path" debe tener como máximo $maxLength caracteres');
      }
    } else if (value is num) {
      final minimum = schema['minimum'];
      final maximum = schema['maximum'];
      if (minimum is num && value < minimum) {
        problems.add('"$path" debe ser mayor o igual que $minimum');
      }
      if (maximum is num && value > maximum) {
        problems.add('"$path" debe ser menor o igual que $maximum');
      }
    } else if (value is Map) {
      problems.addAll(_validateObject(
        schema,
        value.map((final key, final item) => MapEntry(key.toString(), item)),
        path,
      ));
    } else if (value is List) {
      final minItems = schema['minItems'];
      final maxItems = schema['maxItems'];
      if (minItems is int && value.length < minItems) {
        problems.add('"$path" debe contener al menos $minItems elementos');
      }
      if (maxItems is int && value.length > maxItems) {
        problems.add('"$path" debe contener como máximo $maxItems elementos');
      }
      final rawItems = schema['items'];
      if (rawItems is Map) {
        final itemSchema = rawItems.map(
          (final key, final item) => MapEntry(key.toString(), item),
        );
        for (var index = 0; index < value.length; index++) {
          problems.addAll(_validateValue('$path[$index]', itemSchema, value[index]));
        }
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
      'array' => value is List,
      'object' => value is Map,
      null => true,
      _ => true,
    };
    if (ok) return null;
    return '"$key" debe ser de tipo $type (recibido ${value.runtimeType})';
  }
}
