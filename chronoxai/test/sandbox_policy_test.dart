import 'package:chronoxai/domain/plugins/sandbox_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = SandboxPolicy();

  test('blocks obvious destructive commands', () {
    expect(policy.violation('rm -rf /'), isNotNull);
    expect(policy.violation('sudo mkfs.ext4 /dev/sda'), isNotNull);
    expect(policy.violation('dd if=/dev/zero of=/dev/sda bs=1M'), isNotNull);
    expect(policy.violation(':(){ :|:& };:'), isNotNull);
  });

  test('allows ordinary workspace operations and safe root paths', () {
    expect(policy.violation('rm -rf /workspace/build'), isNull);
    expect(policy.violation('ls -la /'), isNull);
    expect(policy.violation('git status --short'), isNull);
  });
}
