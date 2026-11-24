import 'package:flutter/services.dart';

/// Small Android Keystore-backed secret store. Secret values are encrypted
/// with AES-GCM; only ciphertext is persisted in app preferences.
class SecureSecretStore {
  const SecureSecretStore({MethodChannel channel = _defaultChannel})
      : _channel = channel;

  static const MethodChannel _defaultChannel =
      MethodChannel('app.chronoxai/secure_store');
  final MethodChannel _channel;

  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', <String, Object?>{'key': key});

  Future<void> write(String key, String value) => _channel.invokeMethod<void>(
        'write',
        <String, Object?>{'key': key, 'value': value},
      );

  Future<void> delete(String key) => _channel.invokeMethod<void>(
        'delete',
        <String, Object?>{'key': key},
      );
}
