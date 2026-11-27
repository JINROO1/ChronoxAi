/// Heurística de defensa en profundidad para comandos destructivos obvios.
/// No es un parser de shell ni un sandbox; plugins y shell arbitrario siguen
/// sujetos a la seguridad del UID Android y la aprobación de herramientas.
class SandboxPolicy {
  const SandboxPolicy();

  static final List<({RegExp pattern, String reason})> _blocked = [
    (
      pattern: RegExp(
          r'(^|[;&|\s])rm\s+[^\n]*-([^\n]*r[^\n]*f|[^\n]*f[^\n]*r)[^\n]*\s+/(\s|$)'),
      reason: 'rm recursivo sobre la raíz'
    ),
    (
      pattern: RegExp(r'(^|[;&|\s])(mkfs(\.[\w-]+)?|mkswap)(\s|$)'),
      reason: 'formateo de dispositivo'
    ),
    (
      pattern: RegExp(r'(^|\s)dd\s+[^\n]*\bof\s*=\s*/dev/'),
      reason: 'escritura directa a dispositivo'
    ),
    (
      pattern: RegExp(r':\s*\(\s*\)\s*\{\s*:|\bfork\s*\(\s*\)'),
      reason: 'posible fork bomb'
    ),
  ];

  String? violation(String command) {
    for (final rule in _blocked) {
      if (rule.pattern.hasMatch(command)) return rule.reason;
    }
    return null;
  }
}
