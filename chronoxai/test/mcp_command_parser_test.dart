import 'package:chronoxai/domain/plugins/mcp_command_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps quoted command arguments as literal process args', () {
    expect(
      parseMcpStdioCommand(
          'npx --yes @scope/server-mcp "/workspace/My Project"'),
      <String>['npx', '--yes', '@scope/server-mcp', '/workspace/My Project'],
    );
  });

  test('rejects unfinished quotes and escapes', () {
    expect(
        () => parseMcpStdioCommand('node "server.js'), throwsFormatException);
    final trailingEscape = 'node server.js ${String.fromCharCode(92)}';
    expect(() => parseMcpStdioCommand(trailingEscape), throwsFormatException);
  });
}
