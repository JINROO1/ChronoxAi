import 'package:chronoxai/domain/plugins/mcp_server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ignores disabled and blank entries but preserves server indices', () {
    final entries = parseMcpServerEntries(
      'https://one.example/mcp\n#stdio:npx disabled\n\nstdio:npx --yes live-server',
    );

    expect(entries, hasLength(2));
    expect(entries[0].index, 0);
    expect(entries[0].command, 'https://one.example/mcp');
    expect(entries[1].index, 3);
    expect(entries[1].command, 'stdio:npx --yes live-server');
  });
}
