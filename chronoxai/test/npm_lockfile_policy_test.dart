import 'dart:convert';

import 'package:chronoxai/domain/plugins/npm_lockfile_policy.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> lockfile(String resolved) => <String, Object?>{
      'lockfileVersion': 3,
      'packages': <String, Object?>{
        '': <String, Object?>{
          'dependencies': <String, String>{'@scope/server': '1.2.3'},
        },
        'node_modules/@scope/server': <String, Object?>{
          'version': '1.2.3',
          'resolved': resolved,
          'integrity': 'sha512-YWJjZA==',
        },
      },
    };

void main() {
  test('accepts a pinned registry package with integrity', () {
    expect(
      () => NpmLockfilePolicy.validateJson(
        jsonEncode(lockfile(
          'https://registry.npmjs.org/@scope/server/-/server-1.2.3.tgz',
        )),
        expectedPackage: '@scope/server',
        expectedVersion: '1.2.3',
      ),
      returnsNormally,
    );
  });

  test('rejects custom registries and missing integrity', () {
    expect(
      () => NpmLockfilePolicy.validateJson(
        jsonEncode(lockfile('https://example.invalid/server.tgz')),
        expectedPackage: '@scope/server',
        expectedVersion: '1.2.3',
      ),
      throwsFormatException,
    );
    final noIntegrity = lockfile('https://registry.npmjs.org/server.tgz');
    ((noIntegrity['packages']!
                as Map<String, Object?>)['node_modules/@scope/server']!
            as Map<String, Object?>)
        .remove('integrity');
    expect(
      () => NpmLockfilePolicy.validateJson(
        jsonEncode(noIntegrity),
        expectedPackage: '@scope/server',
        expectedVersion: '1.2.3',
      ),
      throwsFormatException,
    );
  });
}
