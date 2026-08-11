import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

enum DeviceRole {
  laptop,
  phone;

  String get key => switch (this) {
    DeviceRole.laptop => 'laptop',
    DeviceRole.phone => 'phone',
  };

  String get label => switch (this) {
    DeviceRole.laptop => 'Laptop',
    DeviceRole.phone => 'Phone',
  };

  static DeviceRole fromKey(String? value) {
    return value == DeviceRole.phone.key ? DeviceRole.phone : DeviceRole.laptop;
  }
}

enum ConnectivityMode {
  wifi,
  net;

  String get label =>
      name == ConnectivityMode.wifi.name ? 'WiFi (Local)' : 'Internet (Cloud)';
  String get key => name;
}

DeviceRole detectDeviceRole() {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => DeviceRole.phone,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => DeviceRole.laptop,
  };
}

String platformName() {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}

String generatePairingCode({Random? random}) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final source = random ?? Random.secure();
  return List.generate(
    10,
    (_) => alphabet[source.nextInt(alphabet.length)],
  ).join();
}

String sanitizePairingCode(String value) {
  final normalized = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return normalized.isEmpty ? generatePairingCode() : normalized;
}

DateTime? readFirestoreDate(Object? value) {
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  return null;
}

class WindowEntry {
  const WindowEntry({
    required this.id,
    required this.title,
    required this.process,
    this.pid,
  });

  factory WindowEntry.fromMap(Map<String, Object?> data) {
    return WindowEntry(
      id: (data['id'] ?? '').toString(),
      title: (data['title'] ?? 'Untitled').toString(),
      process: (data['process'] ?? 'Unknown').toString(),
      pid: data['pid'] is int ? data['pid'] as int : null,
    );
  }

  final String id;
  final String title;
  final String process;
  final int? pid;

  String get fingerprint => '$process::$title';

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'process': process,
      if (pid != null) 'pid': pid,
    };
  }
}

class MediaState {
  const MediaState({
    required this.title,
    required this.artist,
    required this.album,
    required this.sourceApp,
    required this.isPlaying,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  factory MediaState.fromMap(Map<String, Object?> data) {
    final position = data['positionMs'];
    final duration = data['durationMs'];
    return MediaState(
      title: (data['title'] ?? 'Laptop media').toString(),
      artist: (data['artist'] ?? '').toString(),
      album: (data['album'] ?? '').toString(),
      sourceApp: (data['sourceApp'] ?? '').toString(),
      isPlaying: data['isPlaying'] == true,
      positionMs: position is num ? position.toInt() : 0,
      durationMs: duration is num ? duration.toInt() : 0,
      updatedAt: readFirestoreDate(data['updatedAt']) ?? DateTime.now(),
    );
  }

  final String title;
  final String artist;
  final String album;
  final String sourceApp;
  final bool isPlaying;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  Map<String, Object?> toMap() {
    return {
      'title': title,
      'artist': artist,
      'album': album,
      'sourceApp': sourceApp,
      'isPlaying': isPlaying,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}

class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.role,
    required this.label,
    required this.platform,
    required this.lastSeen,
    required this.online,
    required this.windows,
    this.volume,
    this.muted,
    this.adminEnabled,
    this.autoStartEnabled,
    this.canPostNotifications,
    this.notificationAccessEnabled,
    this.remoteUnlockReady = false,
    this.media,
    this.localIp,
    this.connectivityMode = ConnectivityMode.wifi,
    this.clipboard,
    this.clipboardSync = false,
  });

  factory RemoteDevice.fromDoc(String id, Map<String, Object?> data) {
    final windows = (data['windows'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => WindowEntry.fromMap(item.cast<String, Object?>()))
        .toList();

    final volumeValue = data['volume'];
    final mutedValue = data['muted'];
    final mediaValue = data['media'];

    return RemoteDevice(
      id: id,
      role: DeviceRole.fromKey(data['role']?.toString()),
      label: (data['label'] ?? 'Unknown device').toString(),
      platform: (data['platform'] ?? 'Unknown').toString(),
      lastSeen: readFirestoreDate(data['lastSeen']),
      online: data['online'] == true,
      windows: windows,
      volume: volumeValue is num ? volumeValue.toDouble() : null,
      muted: mutedValue is bool ? mutedValue : null,
      adminEnabled: data['adminEnabled'] is bool
          ? data['adminEnabled'] as bool
          : null,
      autoStartEnabled: data['autoStartEnabled'] is bool
          ? data['autoStartEnabled'] as bool
          : null,
      canPostNotifications: data['canPostNotifications'] is bool
          ? data['canPostNotifications'] as bool
          : null,
      notificationAccessEnabled: data['notificationAccessEnabled'] is bool
          ? data['notificationAccessEnabled'] as bool
          : null,
      remoteUnlockReady: data['remoteUnlockReady'] == true,
      localIp: (data['localIp'] ?? '').toString(),
      connectivityMode: ConnectivityMode.values.firstWhere(
        (m) => m.key == data['connectivityMode'],
        orElse: () => ConnectivityMode.wifi,
      ),
      media: mediaValue is Map
          ? MediaState.fromMap(mediaValue.cast<String, Object?>())
          : null,
      clipboard: (data['clipboard'] as String?),
      clipboardSync: data['clipboardSync'] == true,
    );
  }

  final String id;
  final DeviceRole role;
  final String label;
  final String platform;
  final DateTime? lastSeen;
  final bool online;
  final List<WindowEntry> windows;
  final double? volume;
  final bool? muted;
  final bool? adminEnabled;
  final bool? autoStartEnabled;
  final bool? canPostNotifications;
  final bool? notificationAccessEnabled;
  final bool remoteUnlockReady;
  final String? localIp;
  final ConnectivityMode connectivityMode;
  final MediaState? media;
  final String? clipboard;
  final bool clipboardSync;
}

class ActivityEvent {
  const ActivityEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.detail,
    required this.source,
    required this.createdAt,
    this.originalTime,
    this.package,
  });

  factory ActivityEvent.fromDoc(String id, Map<String, Object?> data) {
    return ActivityEvent(
      id: id,
      type: (data['type'] ?? 'event').toString(),
      title: (data['title'] ?? 'Activity').toString(),
      detail: (data['detail'] ?? '').toString(),
      source: DeviceRole.fromKey(data['source']?.toString()),
      createdAt: readFirestoreDate(data['createdAt']) ?? DateTime.now(),
      originalTime: readFirestoreDate(data['originalTime']),
      package: (data['package'] as String?),
    );
  }

  final String id;
  final String type;
  final String title;
  final String detail;
  final DeviceRole source;
  final DateTime createdAt;
  final DateTime? originalTime;
  final String? package;
}
