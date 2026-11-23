import 'dart:io';

import 'package:flutter/services.dart';

/// Permisos y ajustes del sistema que la app necesita para funcionar de verdad.
///
/// No basta con declararlos en el manifiesto:
///
/// * **Android 13+** exige `POST_NOTIFICATIONS` en tiempo de ejecución. Sin él,
///   el servicio en primer plano no se ve y el usuario cree que la app se colgó.
/// * **Cualquier Android** puede congelar el proceso en segundo plano. La
///   exclusión de optimización de batería es lo que permite que un
///   `apt install` largo termine con la pantalla apagada.
///
/// Se piden siempre desde la UI visible y de forma **opcional**: negarse no debe
/// impedir usar la app, solo degradarla (y avisar de que se degrada).
class AndroidPermissions {
  const AndroidPermissions([this._channel = _defaultChannel]);

  /// Permite forzar el camino de Android en los tests (ver
  /// `AndroidRuntimeChannel.debugTargetPlatform`).
  static TargetPlatform? debugTargetPlatform;

  static bool get _isAndroid =>
      debugTargetPlatform == TargetPlatform.android || Platform.isAndroid;

  static const MethodChannel _defaultChannel =
      MethodChannel('app.chronoxai/permissions');

  final MethodChannel _channel;

  /// Pide el permiso de notificaciones (Android 13+). Devuelve si se concedió.
  ///
  /// En versiones anteriores devuelve `true` sin mostrar nada: el permiso no
  /// existe y pedirlo sería un no-op confuso.
  Future<bool> requestNotifications() async {
    if (!_isAndroid) return true;
    try {
      final granted =
          await _channel.invokeMethod<Object?>('requestNotifications');
      return granted is bool ? granted : false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// `true` si la app está excluida de la optimización de batería.
  Future<bool> isBatteryUnrestricted() async {
    if (!_isAndroid) return true;
    try {
      final value =
          await _channel.invokeMethod<Object?>('isBatteryUnrestricted');
      return value is bool ? value : false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Abre el diálogo del sistema para excluir la app de la optimización.
  ///
  /// Se usa el intent del sistema y no un ajuste propio: la lista de apps
  /// "sin restricciones" es distinta en cada ROM (MIUI, RedMagic OS, One UI…) y
  /// adivinar el nombre del paquete de ajustes no es fiable.
  Future<void> requestBatteryUnrestricted() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestBatteryUnrestricted');
    } on MissingPluginException {
      // Sin canal (tests, escritorio): no hay nada que pedir.
    } on PlatformException {
      // El usuario cerró el diálogo: se respeta y no se insiste.
    }
  }

  /// Arranca el servicio en primer plano que mantiene viva la sesión.
  Future<bool> startTerminalService(
      {final String title = 'Sesión activa'}) async {
    if (!_isAndroid) return false;
    try {
      final started = await _channel.invokeMethod<Object?>(
        'startTerminalService',
        <String, Object?>{'title': title},
      );
      return started is bool ? started : false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Detiene el servicio en primer plano.
  Future<void> stopTerminalService() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopTerminalService');
    } on MissingPluginException {
      // Nada que parar.
    } on PlatformException {
      // El servicio ya no estaba.
    }
  }
}
