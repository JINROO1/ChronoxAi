import 'package:chronoxai/platform/voice_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/voice');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('requests native recognition and returns the transcription', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (final call) async {
      expect(call.method, 'recognize');
      return 'Hola Chronox';
    });

    expect(await VoiceChannel(channel).recognize(), 'Hola Chronox');
  });
}
