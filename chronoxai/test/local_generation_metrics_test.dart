import 'package:chronoxai/platform/android_local_inference_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports sustained generation rate without dividing by zero', () {
    const measured = LocalGenerationMetrics(
      generatedTokens: 50,
      elapsedMilliseconds: 5000,
    );
    const instantaneous = LocalGenerationMetrics(
      generatedTokens: 1,
      elapsedMilliseconds: 0,
    );

    expect(measured.tokensPerSecond, 10);
    expect(instantaneous.tokensPerSecond, 0);
  });
}
