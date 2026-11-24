/// A configured MCP server with its stable position in the settings list.
class McpServerEntry {
  const McpServerEntry({required this.index, required this.command});

  final int index;
  final String command;
}

/// Reads one HTTP URL or `stdio:` command per line. Prefixing a row with `#`
/// disables it while preserving its position, so tool names remain stable.
List<McpServerEntry> parseMcpServerEntries(String configuration) {
  final rows = configuration.split('\n');
  final entries = <McpServerEntry>[];
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index].trim();
    if (row.isEmpty || row.startsWith('#')) continue;
    entries.add(McpServerEntry(index: index, command: row));
  }
  return entries;
}
