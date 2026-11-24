/// A configured MCP server with its stable position in the settings list.
class McpServerEntry {
  const McpServerEntry({
    required this.index,
    required this.command,
    required this.requiresApproval,
  });

  final int index;
  final String command;
  final bool requiresApproval;
}

/// Reads one HTTP URL or `stdio:` command per line. `#` disables a row; `!`
/// opts that server out of per-call approval. Both markers preserve row positions.
/// Unmarked servers always require approval for each tool call.
List<McpServerEntry> parseMcpServerEntries(String configuration) {
  final rows = configuration.split('\n');
  final entries = <McpServerEntry>[];
  for (var index = 0; index < rows.length; index++) {
    var row = rows[index].trim();
    if (row.isEmpty || row.startsWith('#')) continue;
    final requiresApproval = !row.startsWith('!');
    if (!requiresApproval) row = row.substring(1).trim();
    if (row.isEmpty) continue;
    entries.add(McpServerEntry(
      index: index,
      command: row,
      requiresApproval: requiresApproval,
    ));
  }
  return entries;
}
