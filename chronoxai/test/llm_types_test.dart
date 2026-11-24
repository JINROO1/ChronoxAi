import 'dart:convert';

import 'package:chronoxai/domain/llm/llm_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tool call arguments use JSON text required by OpenAI-compatible APIs', () {
    final json = LlmToolCall(
      id: 'call-1',
      name: 'bash',
      arguments: <String, Object?>{'command': 'echo hello', 'timeout': 20},
    ).toJson();
    final function = json['function']! as Map<String, Object?>;
    expect(function['arguments'], isA<String>());
    expect(jsonDecode(function['arguments']! as String), <String, Object?>{
      'command': 'echo hello',
      'timeout': 20,
    });
  });
}
