/// Tokenizes the deliberately small command syntax used for MCP stdio settings.
/// Quotes group a single argument; shell expansions, pipes and substitutions
/// are not interpreted, since each token is passed as a literal process arg.
List<String> parseMcpStdioCommand(String source) {
  final tokens = <String>[];
  final current = StringBuffer();
  String? quote;
  var escaped = false;
  var started = false;

  void finish() {
    if (!started) return;
    tokens.add(current.toString());
    current.clear();
    started = false;
  }

  for (final char in source.trim().split('')) {
    if (escaped) {
      current.write(char);
      escaped = false;
      started = true;
    } else if (char.codeUnitAt(0) == 92 && quote != "'") {
      escaped = true;
      started = true;
    } else if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        current.write(char);
      }
      started = true;
    } else if (char == "'" || char == '"') {
      quote = char;
      started = true;
    } else if (RegExp(r'\s').hasMatch(char)) {
      finish();
    } else {
      current.write(char);
      started = true;
    }
  }
  if (escaped || quote != null) {
    throw const FormatException(
        'Comillas o escape sin cerrar en el comando MCP.');
  }
  finish();
  return tokens;
}
