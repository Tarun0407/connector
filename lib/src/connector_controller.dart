import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import 'models.dart';
import 'platform_bridge.dart';

class ConnectorController extends ChangeNotifier {
  ConnectorController({ConnectorPlatformBridge? platformBridge, Random? random})
    : platform = platformBridge ?? ConnectorPlatformBridge(),
      _random = random,
      role = detectDeviceRole();

  static const Duration _idleDesktopPollInterval = Duration(seconds: 20);
  static const Duration _activeMediaPollInterval = Duration(minutes: 1);

  final ConnectorPlatformBridge platform;
  final Random? _random;
  final DeviceRole role;

  bool isBooting = true;
  bool firebaseReady = false;
  String? firebaseError;
  String? roomCode;
  String deviceId = '';
  String deviceLabel = '';
  String statusMessage = 'Starting';
  List<RemoteDevice> devices = const [];
  List<ActivityEvent> events = const [];
  List<WindowEntry> windows = const [];
  double? laptopVolume;
  bool? laptopMuted;
  MediaState? laptopMedia;
  bool phoneAdminEnabled = false;
  bool autoStartEnabled = false;
  bool canPostNotifications = false;
  bool notificationAccessEnabled = false;
  bool windowsUnlockPasswordSaved = false;

  SharedPreferences? _preferences;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _devicesSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _eventsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _commandsSub;
  StreamSubscription<Map<String, Object?>>? _phoneNotificationsSub;
  StreamSubscription<Map<String, Object?>>? _laptopMediaActionsSub;
  Timer? _heartbeatTimer;
  Timer? _desktopPollTimer;
  Timer? _presenceCheckTimer;
  final Set<String> _handledCommands = <String>{};
  final Set<String> _shownSystemNotificationIds = <String>{};
  Set<String> _knownWindowFingerprints = <String>{};
  bool _disposed = false;

  RemoteDevice? get primaryLaptop => _firstDevice(DeviceRole.laptop);

  RemoteDevice? get primaryPhone => _firstDevice(DeviceRole.phone);

  bool get hasRoom => roomCode != null && roomCode!.isNotEmpty;

  bool isDeviceOnline(RemoteDevice device) {
    if (!device.online || device.lastSeen == null) {
      return false;
    }

    return DateTime.now().difference(device.lastSeen!) <
        const Duration(minutes: 3);
  }

  Future<void> start() async {
    isBooting = true;
    _safeNotify();

    _preferences = await SharedPreferences.getInstance();
    deviceId = _preferences!.getString('connector.deviceId') ?? _newDeviceId();
    await _preferences!.setString('connector.deviceId', deviceId);

    deviceLabel =
        _preferences!.getString('connector.deviceLabel') ??
        '${platformName()} ${role.label}';
    roomCode =
        _preferences!.getString('connector.roomCode') ??
        generatePairingCode(random: _random);
    await _preferences!.setString('connector.roomCode', roomCode!);

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      await FirebaseAuth.instance.signInAnonymously();
      firebaseReady = true;
      firebaseError = null;
    } on Object catch (error) {
      firebaseReady = false;
      firebaseError = error.toString();
      statusMessage = 'Firebase setup required';
    }

    if (firebaseReady && roomCode != null) {
      await joinRoom(roomCode!, notifyWhenDone: false);
    }

    if (role == DeviceRole.phone) {
      await refreshPhoneState();
    } else {
      await refreshWindowsUnlockState();
    }
    await refreshAutoStart();
    _listenForLocalPhoneNotifications();
    _listenForLaptopMediaNotificationActions();

    isBooting = false;
    _safeNotify();
  }

  Future<void> joinRoom(String rawCode, {bool notifyWhenDone = true}) async {
    final nextCode = sanitizePairingCode(rawCode);
    roomCode = nextCode;
    await _preferences?.setString('connector.roomCode', nextCode);

    if (!firebaseReady) {
      statusMessage = 'Firebase setup required';
      if (notifyWhenDone) {
        _safeNotify();
      }
      return;
    }

    await _cancelRoomSubscriptions();
    await _roomRef.set({
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'pairingVersion': 1,
    }, SetOptions(merge: true));

    await _updatePresence();
    _listenForDevices();
    _listenForEvents();
    _listenForCommands();
    _listenForLaptopMediaNotificationActions();
    _startHeartbeat();
    _startPresenceChecks();

    if (role == DeviceRole.laptop) {
      _startDesktopPolling();
    }

    statusMessage = 'Connected to $nextCode';
    if (notifyWhenDone) {
      _safeNotify();
    }
  }

  Future<void> generateNewRoom() async {
    await joinRoom(generatePairingCode(random: _random));
  }

  Future<void> refreshPhoneState() async {
    if (role != DeviceRole.phone) {
      return;
    }
    phoneAdminEnabled = await platform.isDeviceAdmin();
    canPostNotifications = await platform.canPostNotifications();
    notificationAccessEnabled = await platform.isNotificationAccessEnabled();
    await _updatePresence(
      extra: {
        'adminEnabled': phoneAdminEnabled,
        'canPostNotifications': canPostNotifications,
        'notificationAccessEnabled': notificationAccessEnabled,
      },
    );
    _safeNotify();
  }

  Future<void> openNotificationAccessSettings() async {
    await platform.requestPostNotifications();
    await platform.openNotificationAccessSettings();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await refreshPhoneState();
  }

  Future<void> requestNotificationSendingPermission() async {
    canPostNotifications = await platform.requestPostNotifications();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    canPostNotifications = await platform.canPostNotifications();
    await _updatePresence(
      extra: {'canPostNotifications': canPostNotifications},
    );
    _safeNotify();
  }

  Future<void> refreshAutoStart() async {
    autoStartEnabled = await platform.isAutoStartEnabled();
    await _updatePresence(extra: {'autoStartEnabled': autoStartEnabled});
    _safeNotify();
  }

  Future<void> setAutoStart(bool enabled) async {
    if (role == DeviceRole.phone && enabled) {
      await requestNotificationSendingPermission();
    }
    final updated = await platform.setAutoStart(enabled);
    autoStartEnabled = updated && enabled;
    await _updatePresence(extra: {'autoStartEnabled': autoStartEnabled});
    _safeNotify();
  }

  Future<void> openAutoStartSettings() {
    return platform.openAutoStartSettings();
  }

  Future<void> requestPhoneAdminLocally() async {
    await platform.requestDeviceAdmin();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await refreshPhoneState();
  }

  Future<void> refreshWindowsUnlockState() async {
    if (role != DeviceRole.laptop) {
      return;
    }
    windowsUnlockPasswordSaved = await platform.hasWindowsUnlockPassword();
    await _updatePresence(
      extra: {'remoteUnlockReady': windowsUnlockPasswordSaved},
    );
    _safeNotify();
  }

  Future<bool> saveWindowsUnlockPassword(String password) async {
    if (role != DeviceRole.laptop) {
      return false;
    }
    final trimmed = password.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final saved = await platform.saveWindowsUnlockPassword(trimmed);
    windowsUnlockPasswordSaved = saved;
    await _updatePresence(extra: {'remoteUnlockReady': saved});
    _safeNotify();
    return saved;
  }

  Future<void> clearWindowsUnlockPassword() async {
    if (role != DeviceRole.laptop) {
      return;
    }
    await platform.clearWindowsUnlockPassword();
    windowsUnlockPasswordSaved = false;
    await _updatePresence(extra: {'remoteUnlockReady': false});
    _safeNotify();
  }

  Future<void> unlockLaptopFromPhone() async {
    if (role != DeviceRole.phone) {
      return;
    }
    final authenticated = await platform.authenticateForRemoteUnlock();
    if (!authenticated) {
      statusMessage = 'Unlock cancelled';
      _safeNotify();
      return;
    }
    await sendLaptopCommand('laptop.unlock');
  }

  Future<void> sendPhoneCommand(String type) {
    return sendCommand(DeviceRole.phone, type);
  }

  Future<void> sendLaptopCommand(
    String type, {
    Map<String, Object?> payload = const {},
  }) {
    return sendCommand(DeviceRole.laptop, type, payload: payload);
  }

  Future<void> sendCommand(
    DeviceRole target,
    String type, {
    Map<String, Object?> payload = const {},
  }) async {
    if (!firebaseReady || !hasRoom) {
      statusMessage = 'Firebase setup required';
      _safeNotify();
      return;
    }

    // Optimization: Check if there's already a queued command of the same type
    // to avoid flooding the database if the user clicks repeatedly.
    final existing = await _roomRef
        .collection('commands')
        .where('target', isEqualTo: target.key)
        .where('type', isEqualTo: type)
        .where('status', isEqualTo: 'queued')
        .limit(1)
        .get();

    if (existing.docs.isNotEmpty) {
      statusMessage = 'Command already queued';
      _safeNotify();
      return;
    }

    await _roomRef.collection('commands').add({
      'type': type,
      'target': target.key,
      'source': role.key,
      'sourceDeviceId': deviceId,
      'payload': payload,
      'status': 'queued',
      'createdAt': FieldValue.serverTimestamp(),
    });

    statusMessage = 'Sent ${_readableCommand(type)}';
    _safeNotify();
  }

  Future<void> refreshDesktopSnapshot({bool publishChanges = false}) async {
    if (role != DeviceRole.laptop) {
      return;
    }

    final fetchedWindows = await platform.listWindows();
    final fetchedVolume = await platform.getVolume();
    final fetchedMuted = await platform.isMuted();
    final fetchedMedia = await platform.getMediaStatus();

    if (publishChanges) {
      await _publishWindowDiff(fetchedWindows);
    } else if (_knownWindowFingerprints.isEmpty) {
      _knownWindowFingerprints = fetchedWindows
          .map((window) => window.fingerprint)
          .where((fingerprint) => fingerprint.trim().isNotEmpty)
          .toSet();
    }

    windows = fetchedWindows;
    laptopVolume = fetchedVolume;
    laptopMuted = fetchedMuted;
    laptopMedia = fetchedMedia;

    await _updatePresence(
      extra: {
        'windows': fetchedWindows
            .take(40)
            .map((window) => window.toMap())
            .toList(),
        'openWindowCount': fetchedWindows.length,
        'volume': fetchedVolume ?? FieldValue.delete(),
        'muted': fetchedMuted ?? FieldValue.delete(),
        'media': fetchedMedia?.toMap() ?? FieldValue.delete(),
      },
    );
    _safeNotify();
  }

  Future<void> _executeCommand(
    String type,
    Map<String, Object?> payload,
  ) async {
    switch (type) {
      case 'laptop.media.toggle':
        await platform.mediaPlayPause();
        return;
      case 'laptop.media.next':
        await platform.mediaNext();
        return;
      case 'laptop.media.previous':
        await platform.mediaPrevious();
        return;
      case 'laptop.media.seek':
        final position = payload['positionMs'];
        await platform.mediaSeek(position is num ? position.toInt() : 0);
        return;
      case 'laptop.volume.up':
        await platform.volumeUp();
        return;
      case 'laptop.volume.down':
        await platform.volumeDown();
        return;
      case 'laptop.volume.mute':
        await platform.volumeMute();
        return;
      case 'laptop.volume.set':
        final level = payload['level'];
        await platform.setVolume(level is num ? level.toDouble() : 50);
        return;
      case 'laptop.lock':
        await platform.lockComputer();
        return;
      case 'laptop.unlock':
        final errorCode = await platform.unlockComputer();
        if (errorCode != 0) {
          throw StateError(_getUnlockErrorMessage(errorCode));
        }
        return;
      case 'laptop.refresh':
        await refreshDesktopSnapshot(publishChanges: false);
        return;
      case 'phone.ring':
        await platform.ringPhone();
        return;
      case 'phone.stopRing':
        await platform.stopRingPhone();
        return;
      case 'phone.lock':
        await platform.lockPhone();
        await refreshPhoneState();
        return;
      case 'phone.requestAdmin':
        await platform.requestDeviceAdmin();
        await refreshPhoneState();
        return;
      default:
        throw UnsupportedError('Unknown command: $type');
    }
  }

  void _listenForDevices() {
    _devicesSub = _roomRef.collection('devices').snapshots().listen((snapshot) {
      devices =
          snapshot.docs
              .map((doc) => RemoteDevice.fromDoc(doc.id, doc.data()))
              .toList()
            ..sort((a, b) => a.role.index.compareTo(b.role.index));
      if (role == DeviceRole.phone) {
        final laptop = primaryLaptop;
        final media = laptop?.media;
        if (laptop == null || media == null || !isDeviceOnline(laptop)) {
          unawaited(platform.cancelLaptopMediaNotification());
        } else {
          unawaited(platform.showLaptopMediaNotification(media));
        }
      }
      _safeNotify();
    });
  }

  void _listenForEvents() {
    _eventsSub = _roomRef
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(80)
        .snapshots()
        .listen((snapshot) {
          events = snapshot.docs
              .map((doc) => ActivityEvent.fromDoc(doc.id, doc.data()))
              .toList();
          if (role == DeviceRole.laptop) {
            _showNewPhoneNotifications(events);
          }
          _safeNotify();
        });
  }

  void _showNewPhoneNotifications(List<ActivityEvent> nextEvents) {
    for (final event in nextEvents.take(8)) {
      if (event.type != 'phone.notification' ||
          event.source != DeviceRole.phone ||
          _shownSystemNotificationIds.contains(event.id)) {
        continue;
      }
      _shownSystemNotificationIds.add(event.id);
      final body = _notificationBody(event);
      unawaited(
        platform.showSystemNotification(title: event.title, body: body),
      );
    }
  }

  String _notificationBody(ActivityEvent event) {
    final time = event.originalTime;
    if (time == null) {
      return event.detail;
    }

    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute  ${event.detail}';
  }

  void _listenForLocalPhoneNotifications() {
    if (role != DeviceRole.phone) {
      return;
    }

    _phoneNotificationsSub?.cancel();
    _phoneNotificationsSub = platform.phoneNotifications.listen((data) {
      final packageName = (data['package'] ?? 'Android').toString();
      final title = (data['title'] ?? packageName).toString();
      final text = (data['text'] ?? '').toString();
      final postedAtValue = data['postedAt'];
      final originalTime = postedAtValue is num
          ? DateTime.fromMillisecondsSinceEpoch(postedAtValue.toInt())
          : null;
      unawaited(
        _publishEvent(
          type: 'phone.notification',
          title: title.trim().isEmpty ? packageName : title,
          detail: text.trim().isEmpty ? packageName : text,
          originalTime: originalTime,
        ),
      );
    });
  }

  void _listenForLaptopMediaNotificationActions() {
    if (role != DeviceRole.phone) {
      return;
    }

    _laptopMediaActionsSub?.cancel();
    _laptopMediaActionsSub = platform.laptopMediaActions.listen((data) {
      final action = (data['action'] ?? 'toggle').toString();
      final command = switch (action) {
        'previous' => 'laptop.media.previous',
        'next' => 'laptop.media.next',
        'seek' => 'laptop.media.seek',
        _ => 'laptop.media.toggle',
      };
      final payload = action == 'seek'
          ? <String, Object?>{'positionMs': data['positionMs'] ?? 0}
          : const <String, Object?>{};
      unawaited(sendLaptopCommand(command, payload: payload));
    });
  }

  void _listenForCommands() {
    _commandsSub = _roomRef
        .collection('commands')
        .where('target', isEqualTo: role.key)
        .where('status', isEqualTo: 'queued')
        .snapshots()
        .listen((snapshot) {
          for (final change in snapshot.docChanges) {
            final doc = change.doc;
            if (!doc.exists || _handledCommands.contains(doc.id)) {
              continue;
            }
            _handledCommands.add(doc.id);
            unawaited(_handleCommand(doc));
          }
        });
  }

  Future<void> _handleCommand(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    if (data == null) {
      return;
    }
    final type = (data['type'] ?? '').toString();
    final payload =
        (data['payload'] as Map?)?.cast<String, Object?>() ??
        <String, Object?>{};

    try {
      await doc.reference.update({
        'status': 'processing',
        'startedAt': FieldValue.serverTimestamp(),
      });
      await _executeCommand(type, payload);
      await doc.reference.update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });
      await _publishEvent(
        type: 'command.completed',
        title: _readableCommand(type),
        detail: '${role.label} completed the command',
      );
      statusMessage = 'Completed ${_readableCommand(type)}';
    } on Object catch (error) {
      await doc.reference.update({
        'status': 'failed',
        'completedAt': FieldValue.serverTimestamp(),
        'error': error.toString(),
      });
      await _publishEvent(
        type: 'command.failed',
        title: _readableCommand(type),
        detail: error.toString(),
      );
      statusMessage = 'Command failed';
    }

    if (role == DeviceRole.laptop) {
      await refreshDesktopSnapshot(publishChanges: false);
    }

    _safeNotify();
  }

  Future<void> _publishWindowDiff(List<WindowEntry> nextWindows) async {
    final nextFingerprints = nextWindows
        .map((window) => window.fingerprint)
        .where((fingerprint) => fingerprint.trim().isNotEmpty)
        .toSet();

    if (_knownWindowFingerprints.isEmpty) {
      _knownWindowFingerprints = nextFingerprints;
      return;
    }

    final opened = nextFingerprints.difference(_knownWindowFingerprints);
    final closed = _knownWindowFingerprints.difference(nextFingerprints);

    for (final fingerprint in opened.take(10)) {
      final window = nextWindows.firstWhere(
        (item) => item.fingerprint == fingerprint,
        orElse: () => WindowEntry(
          id: fingerprint,
          title: fingerprint,
          process: 'Unknown',
        ),
      );
      await _publishEvent(
        type: 'window.opened',
        title: 'Opened ${window.title}',
        detail: window.process,
      );
    }

    for (final fingerprint in closed.take(10)) {
      final parts = fingerprint.split('::');
      await _publishEvent(
        type: 'window.closed',
        title: 'Closed ${parts.length > 1 ? parts[1] : fingerprint}',
        detail: parts.first,
      );
    }

    _knownWindowFingerprints = nextFingerprints;
  }

  Future<void> _publishEvent({
    required String type,
    required String title,
    required String detail,
    DateTime? originalTime,
  }) async {
    if (!firebaseReady || !hasRoom) {
      return;
    }

    await _roomRef.collection('events').add({
      'type': type,
      'title': title,
      'detail': detail,
      'source': role.key,
      'sourceDeviceId': deviceId,
      'createdAt': FieldValue.serverTimestamp(),
      if (originalTime != null)
        'originalTime': Timestamp.fromDate(originalTime),
    });
  }

  Future<void> _updatePresence({Map<String, Object?> extra = const {}}) async {
    if (!firebaseReady || !hasRoom) {
      return;
    }

    await _roomRef.collection('devices').doc(deviceId).set({
      'role': role.key,
      'label': deviceLabel,
      'platform': platformName(),
      'online': true,
      'lastSeen': FieldValue.serverTimestamp(),
      'capabilities': _capabilitiesForRole(),
      ...extra,
    }, SetOptions(merge: true));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_updatePresence());
    });
  }

  void _startPresenceChecks() {
    _presenceCheckTimer?.cancel();
    _presenceCheckTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      _safeNotify();
    });
  }

  void _startDesktopPolling() {
    _desktopPollTimer?.cancel();
    _pollDesktopSnapshot(publishChanges: false);
  }

  void _pollDesktopSnapshot({required bool publishChanges}) {
    unawaited(
      refreshDesktopSnapshot(publishChanges: publishChanges).whenComplete(() {
        if (_disposed || role != DeviceRole.laptop) {
          return;
        }

        final delay = laptopMedia == null
            ? _idleDesktopPollInterval
            : _activeMediaPollInterval;
        _desktopPollTimer?.cancel();
        _desktopPollTimer = Timer(delay, () {
          _pollDesktopSnapshot(publishChanges: true);
        });
      }),
    );
  }

  Future<void> _cancelRoomSubscriptions() async {
    _heartbeatTimer?.cancel();
    _desktopPollTimer?.cancel();
    _presenceCheckTimer?.cancel();
    await _devicesSub?.cancel();
    await _eventsSub?.cancel();
    await _commandsSub?.cancel();
    await _phoneNotificationsSub?.cancel();
    await _laptopMediaActionsSub?.cancel();
    _devicesSub = null;
    _eventsSub = null;
    _commandsSub = null;
    _phoneNotificationsSub = null;
    _laptopMediaActionsSub = null;
    _presenceCheckTimer = null;
  }

  DocumentReference<Map<String, dynamic>> get _roomRef {
    return FirebaseFirestore.instance.collection('pairingRooms').doc(roomCode);
  }

  RemoteDevice? _firstDevice(DeviceRole targetRole) {
    for (final device in devices) {
      if (device.role == targetRole && device.id != deviceId) {
        return device;
      }
    }
    for (final device in devices) {
      if (device.role == targetRole) {
        return device;
      }
    }
    return null;
  }

  Map<String, bool> _capabilitiesForRole() {
    return switch (role) {
      DeviceRole.laptop => {
        'media': true,
        'volume': true,
        'lock': true,
        'remoteUnlock': windowsUnlockPasswordSaved,
        'windowLogs': true,
        'autoStart': true,
        'mediaMetadata': true,
      },
      DeviceRole.phone => {
        'ring': true,
        'lock': true,
        'deviceAdmin': true,
        'autoStart': true,
        'notificationMirror': true,
      },
    };
  }

  String _newDeviceId() {
    final entropy = Random.secure().nextInt(1 << 32).toRadixString(16);
    return '${role.key}-${DateTime.now().microsecondsSinceEpoch}-$entropy';
  }

  String _readableCommand(String type) {
    return switch (type) {
      'laptop.media.toggle' => 'media play/pause',
      'laptop.media.next' => 'next track',
      'laptop.media.previous' => 'previous track',
      'laptop.media.seek' => 'seek media',
      'laptop.volume.up' => 'volume up',
      'laptop.volume.down' => 'volume down',
      'laptop.volume.mute' => 'mute toggle',
      'laptop.volume.set' => 'set volume',
      'laptop.lock' => 'lock laptop',
      'laptop.unlock' => 'unlock laptop',
      'laptop.refresh' => 'refresh laptop',
      'phone.ring' => 'locate phone',
      'phone.stopRing' => 'stop ringing',
      'phone.lock' => 'lock phone',
      'phone.requestAdmin' => 'enable phone lock',
      _ => type,
    };
  }

  String _getUnlockErrorMessage(int? code) {
    if (code == null) return 'Unknown error: Remote unlock failed';
    if (code == -1) return 'Password not found: Remote unlock failed';
    if (code == -2) return 'No active session: Remote unlock failed';
    if (code == 5) return 'Access Denied (Error 5): Run as Administrator';
    if (code == 1326)
      return 'Invalid password (Error 1326): Remote unlock failed';
    return 'Windows Error $code: Remote unlock failed';
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_cancelRoomSubscriptions());
    super.dispose();
  }
}
