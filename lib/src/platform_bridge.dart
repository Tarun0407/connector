import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

class ConnectorPlatformBridge {
  static const MethodChannel _channel = MethodChannel('connector/platform');
  final StreamController<Map<String, Object?>> _phoneNotifications =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<Map<String, Object?>> _laptopMediaActions =
      StreamController<Map<String, Object?>>.broadcast();

  ConnectorPlatformBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'phoneNotification') {
        final arguments = call.arguments;
        if (arguments is Map) {
          _phoneNotifications.add(arguments.cast<String, Object?>());
        }
      }
      if (call.method == 'laptopMediaAction') {
        final arguments = call.arguments;
        if (arguments is String) {
          _laptopMediaActions.add({'action': arguments});
        } else if (arguments is Map) {
          _laptopMediaActions.add(arguments.cast<String, Object?>());
        }
      }
    });
  }

  Stream<Map<String, Object?>> get phoneNotifications =>
      _phoneNotifications.stream;

  Stream<Map<String, Object?>> get laptopMediaActions =>
      _laptopMediaActions.stream;

  Future<bool> mediaPlayPause() => _invokeBool('mediaPlayPause');

  Future<bool> mediaNext() => _invokeBool('mediaNext');

  Future<bool> mediaPrevious() => _invokeBool('mediaPrevious');

  Future<bool> mediaSeek(int positionMs) {
    return _invokeBool('mediaSeek', {'positionMs': positionMs});
  }

  Future<MediaState?> getMediaStatus() async {
    final result = await _invoke<Map<dynamic, dynamic>>('getMediaStatus');
    if (result == null || result.isEmpty) {
      return null;
    }
    return MediaState.fromMap(result.cast<String, Object?>());
  }

  Future<bool> volumeUp() => _invokeBool('volumeUp');

  Future<bool> volumeDown() => _invokeBool('volumeDown');

  Future<bool> volumeMute() => _invokeBool('volumeMute');

  Future<bool> lockComputer() => _invokeBool('lockComputer');

  Future<String?> getLocalIp() async {
    final value = await _invoke<Object?>('getLocalIp');
    return value is String ? value : null;
  }

  Future<double?> getVolume() async {
    final value = await _invoke<Object?>('getVolume');
    return value is num ? value.toDouble() : null;
  }

  Future<bool?> isMuted() async {
    final value = await _invoke<Object?>('isMuted');
    return value is bool ? value : null;
  }

  Future<bool> setVolume(double level) {
    return _invokeBool('setVolume', {'level': level.clamp(0, 100).round()});
  }

  Future<List<WindowEntry>> listWindows() async {
    final result = await _invoke<List<dynamic>>('listWindows');
    if (result == null) {
      return const [];
    }

    return result
        .whereType<Map>()
        .map((item) => WindowEntry.fromMap(item.cast<String, Object?>()))
        .toList();
  }

  Future<bool> ringPhone() => _invokeBool('ringPhone');

  Future<bool> stopRingPhone() => _invokeBool('stopRingPhone');

  Future<bool> lockPhone() => _invokeBool('lockPhone');

  Future<bool> requestDeviceAdmin() => _invokeBool('requestDeviceAdmin');

  Future<bool> isDeviceAdmin() => _invokeBool('isDeviceAdmin');

  Future<bool> requestPostNotifications() {
    return _invokeBool('requestPostNotifications');
  }

  Future<bool> canPostNotifications() {
    return _invokeBool('canPostNotifications');
  }

  Future<bool> openNotificationAccessSettings() {
    return _invokeBool('openNotificationAccessSettings');
  }

  Future<bool> isNotificationAccessEnabled() {
    return _invokeBool('isNotificationAccessEnabled');
  }

  Future<bool> setAutoStart(bool enabled) {
    return _invokeBool('setAutoStart', {'enabled': enabled});
  }

  Future<bool> isAutoStartEnabled() => _invokeBool('isAutoStartEnabled');

  Future<bool> openAutoStartSettings() => _invokeBool('openAutoStartSettings');

  Future<bool> showSystemNotification({
    required String title,
    required String body,
  }) {
    return _invokeBool('showSystemNotification', {
      'title': title,
      'body': body,
    });
  }

  Future<bool> minimizeToTray() => _invokeBool('minimizeToTray');

  Future<bool> exitApp() => _invokeBool('exitApp');

  Future<bool> showLaptopMediaNotification(MediaState media) {
    return _invokeBool('showLaptopMediaNotification', {
      'title': media.title,
      'artist': media.artist,
      'album': media.album,
      'sourceApp': media.sourceApp,
      'isPlaying': media.isPlaying,
      'positionMs': media.positionMs,
      'durationMs': media.durationMs,
      'updatedAtMs': media.updatedAt.millisecondsSinceEpoch,
    });
  }

  Future<bool> cancelLaptopMediaNotification() {
    return _invokeBool('cancelLaptopMediaNotification');
  }

  Future<bool> _invokeBool(String method, [Object? arguments]) async {
    final value = await _invoke<Object?>(method, arguments);
    return value == true;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }
}
