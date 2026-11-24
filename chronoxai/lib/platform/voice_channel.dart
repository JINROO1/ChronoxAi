import 'package:flutter/services.dart';

class VoiceChannel {
  const VoiceChannel([this.channel = _defaultChannel]);
  static const MethodChannel _defaultChannel =
      MethodChannel('app.chronoxai/voice');
  final MethodChannel channel;

  Future<String?> recognize() => channel.invokeMethod<String?>('recognize');
}
