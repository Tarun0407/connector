import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import 'models.dart';
import 'platform_bridge.dart';
import 'local_network_client.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_storage/firebase_storage.dart';

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
  final LocalNetworkClient _localClient = LocalNetworkClient();

  bool isBooting = true;
  bool firebaseReady = false;
  String? firebaseError;
  String? roomCode;
  String deviceId = '';
  String deviceLabel = '';
  String statusMessage = 'Starting';
  String? laptopLocalIp;
  String? localIp;
  bool isWifiReachable = false;
  int maxCloudUploadSize = 100;
  List<RemoteDevice> devices = const [];
  List<ActivityEvent> events = const [];
  List<WindowEntry> windows = const [];
  List<String> receivedFiles = const [];
  List<String> phoneReceivedFiles = const [];
  double? uploadProgress;
  int uploadCurrent = 0;
  int uploadTotal = 0;
  double? laptopVolume;
  bool? laptopMuted;
  MediaState? laptopMedia;
  bool phoneAdminEnabled = false;
  bool autoStartEnabled = false;
  bool canPostNotifications = false;
  bool notificationAccessEnabled = false;
  bool clipboardSyncEnabled = false;

  SharedPreferences? _preferences;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _devicesSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _eventsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _commandsSub;
  StreamSubscription<Map<String, Object?>>? _phoneNotificationsSub;
  StreamSubscription<Map<String, Object?>>? _laptopMediaActionsSub;
  ServerSocket? _phoneFileServer;
  Timer? _heartbeatTimer;
  Timer? _desktopPollTimer;
  Timer? _presenceCheckTimer;
  Timer? _clipboardPollTimer;
  String? _lastLocalClipboard;
  String? _lastRemoteClipboard;
  final Set<String> _handledCommands = <String>{};
  final Set<String> _shownSystemNotificationIds = <String>{};
  Set<String> _knownWindowFingerprints = <String>{};
  bool _disposed = false;
  int _roomGeneration = 0;

  RemoteDevice? get primaryLaptop => _firstDevice(DeviceRole.laptop);
  RemoteDevice? get primaryPhone => _firstDevice(DeviceRole.phone);
  bool get hasRoom => roomCode != null && roomCode!.isNotEmpty;

  bool isDeviceOnline(RemoteDevice device) {
    if (!device.online || device.lastSeen == null) return false;
    return DateTime.now().difference(device.lastSeen!) <
        const Duration(minutes: 3);
  }

  Future<void> start() async {
    isBooting = true;
    _safeNotify();

    _preferences = await SharedPreferences.getInstance();

    // Load saved settings
    maxCloudUploadSize =
        _preferences!.getInt('connector.maxCloudUploadSize') ?? 100;
    clipboardSyncEnabled =
        _preferences!.getBool('connector.clipboardSync') ?? false;
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
    } else {
      _listenForLaptopMediaNotificationActions();
    }

    if (role == DeviceRole.phone) {
      await refreshPhoneState();
      _startPhoneFileServer();
    }

    await refreshAutoStart();
    _listenForLocalPhoneNotifications();

    isBooting = false;
    _safeNotify();
  }

  Future<void> joinRoom(String rawCode, {bool notifyWhenDone = true}) async {
    final nextCode = sanitizePairingCode(rawCode);
    roomCode = nextCode;
    await _preferences?.setString('connector.roomCode', nextCode);

    if (!firebaseReady) {
      statusMessage = 'Firebase setup required';
      if (notifyWhenDone) _safeNotify();
      return;
    }

    await _cancelRoomSubscriptions();
    _roomGeneration++;
    _knownWindowFingerprints = <String>{};
    _lastLocalClipboard = null;
    _lastRemoteClipboard = null;
    _shownSystemNotificationIds.clear();
    await _roomRef.set({
      'updatedAt': FieldValue.serverTimestamp(),
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
    if (clipboardSyncEnabled) {
      _startClipboardPolling();
    }

    statusMessage = 'Connected to $nextCode';
    if (notifyWhenDone) _safeNotify();
  }

  Future<void> generateNewRoom() async {
    await joinRoom(generatePairingCode(random: _random));
  }

  Future<void> refreshPhoneState() async {
    if (role != DeviceRole.phone) return;
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

  Future<void> setClipboardSync(bool enabled) async {
    clipboardSyncEnabled = enabled;
    await _preferences?.setBool('connector.clipboardSync', enabled);
    await _updatePresence(extra: {'clipboardSync': enabled});
    if (enabled) {
      _startClipboardPolling();
    } else {
      _stopClipboardPolling();
    }
    _safeNotify();
  }

  void _startClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!clipboardSyncEnabled || _disposed) return;
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final current = data?.text;
        if (current != null && current != _lastLocalClipboard) {
          _lastLocalClipboard = current;
          await _updatePresence(extra: {
            'clipboard': current,
            'clipboardSync': true,
          });
        }
      } catch (_) {}
    });
  }

  void _stopClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = null;
  }

  void _handleRemoteClipboard(String content) {
    if (content == _lastRemoteClipboard || content == _lastLocalClipboard) return;
    _lastRemoteClipboard = content;
    _lastLocalClipboard = content;
    unawaited(Clipboard.setData(ClipboardData(text: content)));
  }

  Future<void> requestPhoneAdminLocally() async {
    await platform.requestDeviceAdmin();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await refreshPhoneState();
  }

  Future<void> setMaxCloudUploadSize(int size) async {
    maxCloudUploadSize = size;
    await _preferences?.setInt('connector.maxCloudUploadSize', size);
    _safeNotify();
  }

  Future<bool> sendFile(File file) async {
    final sizeInMb = (await file.length()) / (1024 * 1024);

    if (isWifiReachable && laptopLocalIp != null) {
      uploadProgress = null;
      _safeNotify();
      final success = await _localClient.sendFile(laptopLocalIp!, file);
      if (success) {
        statusMessage = 'File sent via Local WiFi!';
        _safeNotify();
        return true;
      }
    }

    if (sizeInMb <= maxCloudUploadSize) {
      return await _uploadFileToCloud(file);
    } else {
      statusMessage = 'File too large for Cloud! Connect to WiFi.';
      _safeNotify();
      return false;
    }
  }

  Future<bool> _uploadFileToCloud(File file) async {
    try {
      if (roomCode == null) return false;

      final fileName = file.path.split(Platform.pathSeparator).last;
      final ref = FirebaseStorage.instance.ref().child(
        'uploads/$roomCode/$deviceId/$fileName',
      );

      uploadProgress = 0;
      uploadCurrent = 1;
      uploadTotal = 1;
      _safeNotify();

      final task = ref.putFile(file);
      task.snapshotEvents.listen((snap) {
        if (snap.totalBytes > 0) {
          uploadProgress = snap.bytesTransferred / snap.totalBytes;
          statusMessage = 'Uploading $fileName ${(uploadProgress! * 100).toStringAsFixed(0)}%';
          _safeNotify();
        }
      });

      await task;
      final url = await ref.getDownloadURL();

      uploadProgress = null;
      _safeNotify();

      await sendLaptopCommand(
        'laptop.receiveFile',
        payload: {'url': url, 'fileName': fileName},
      );

      statusMessage = 'File uploaded to Cloud!';
      _safeNotify();
      return true;
    } catch (e) {
      uploadProgress = null;
      statusMessage = 'Cloud upload failed: $e';
      _safeNotify();
      return false;
    }
  }

  Future<void> sendPhoneCommand(String type) {
    return sendCommand(DeviceRole.phone, type);
  }

  void _checkLocalReachability() {
    isWifiReachable = role == DeviceRole.phone
        ? laptopLocalIp != null && laptopLocalIp!.isNotEmpty
        : primaryPhone?.localIp != null && primaryPhone!.localIp!.isNotEmpty;
    _safeNotify();
  }

  Future<void> sendLaptopCommand(
    String type, {
    Map<String, Object?> payload = const {},
  }) async {
    if (isWifiReachable && laptopLocalIp != null) {
      final localCommand = _mapCommandToLocal(type);
      if (localCommand != null) {
        final success = await _localClient.sendCommand(
          laptopLocalIp!,
          localCommand,
        );
        if (success) {
          statusMessage = 'Sent via Local WiFi: ${_readableCommand(type)}';
          _safeNotify();
          return;
        }
      }
    }
    return sendCommand(DeviceRole.laptop, type, payload: payload);
  }

  String? _mapCommandToLocal(String type) {
    return switch (type) {
      'laptop.media.toggle' => 'mediaPlayPause',
      'laptop.media.next' => 'mediaNext',
      'laptop.media.previous' => 'mediaPrevious',
      'laptop.volume.up' => 'volumeUp',
      'laptop.volume.down' => 'volumeDown',
      'laptop.volume.mute' => 'volumeMute',
      'laptop.lock' => 'lock',
      _ => null,
    };
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
    if (role != DeviceRole.laptop) return;

    final fetchedWindows = await platform.listWindows();
    final fetchedVolume = await platform.getVolume();
    final fetchedMuted = await platform.isMuted();
    final fetchedMedia = await platform.getMediaStatus();
    final localIp = await platform.getLocalIp();

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
        'localIp': localIp ?? FieldValue.delete(),
        'wifiReachable': isWifiReachable,
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
      case 'laptop.receiveFile':
        final url = payload['url'] as String?;
        final fileName = payload['fileName'] as String?;
        if (url != null && fileName != null) {
          await _downloadFileToLaptop(url, fileName);
        }
        return;
      case 'phone.receiveFile':
        final url = payload['url'] as String?;
        final fileName = payload['fileName'] as String?;
        if (url != null && fileName != null) {
          await _downloadFileToPhone(url, fileName);
        }
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
        laptopLocalIp = laptop?.localIp;
        _checkLocalReachability();

        final media = laptop?.media;
        if (laptop == null || media == null || !isDeviceOnline(laptop)) {
          unawaited(platform.cancelLaptopMediaNotification());
        } else {
          unawaited(platform.showLaptopMediaNotification(media));
        }
      }

      if (clipboardSyncEnabled) {
        final peer = role == DeviceRole.phone ? primaryLaptop : primaryPhone;
        if (peer != null && peer.clipboardSync && peer.clipboard != null) {
          _handleRemoteClipboard(peer.clipboard!);
        }
      }

      _safeNotify();
    });
  }

  bool _eventsSeeded = false;

  void _listenForEvents() {
    _eventsSeeded = false;
    _eventsSub = _roomRef
        .collection('events')
        .orderBy('createdAt', descending: true)
        .limit(80)
        .snapshots()
        .listen((snapshot) {
          events = snapshot.docs
              .map((doc) => ActivityEvent.fromDoc(doc.id, doc.data()))
              .toList();
          _showNotificationEvents(events);
          _safeNotify();
        });
  }

  void _showNotificationEvents(List<ActivityEvent> nextEvents) {
    if (!_eventsSeeded) {
      for (final event in nextEvents) {
        if (event.type == 'phone.notification' ||
            event.type == 'file.received') {
          _shownSystemNotificationIds.add(event.id);
        }
      }
      _eventsSeeded = true;
      return;
    }
    for (final event in nextEvents) {
      if (_shownSystemNotificationIds.contains(event.id)) continue;
      _shownSystemNotificationIds.add(event.id);
      if (event.type == 'phone.notification' &&
          event.source == DeviceRole.phone &&
          role == DeviceRole.laptop) {
        final body = _notificationBody(event);
        unawaited(
          platform.showSystemNotification(title: event.title, body: body),
        );
      } else if (event.type == 'file.received' &&
          event.source == DeviceRole.laptop &&
          role == DeviceRole.phone) {
        unawaited(
          platform.showSystemNotification(
            title: 'File received on laptop',
            body: event.detail,
          ),
        );
      }
    }
    while (_shownSystemNotificationIds.length > 500) {
      _shownSystemNotificationIds.remove(_shownSystemNotificationIds.first);
    }
  }

  String _notificationBody(ActivityEvent event) {
    final time = event.originalTime;
    if (time == null) return event.detail;
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute  ${event.detail}';
  }

  void _listenForLocalPhoneNotifications() {
    if (role != DeviceRole.phone) return;
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
    if (role != DeviceRole.phone) return;
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
            if (change.type != DocumentChangeType.added) continue;
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
    if (data == null) return;

    if (_handledCommands.length > 500) {
      _handledCommands.clear();
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
    if (!firebaseReady || !hasRoom) return;
    try {
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
    } catch (_) {}
  }

  Future<void> _refreshLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              addr.address.startsWith('192.168.')) {
            localIp = addr.address;
            return;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _updatePresence({Map<String, Object?> extra = const {}}) async {
    if (!firebaseReady || !hasRoom) return;

    await _refreshLocalIp();

    await _roomRef.collection('devices').doc(deviceId).set({
      'role': role.key,
      'label': deviceLabel,
      'platform': platformName(),
      'online': true,
      'lastSeen': FieldValue.serverTimestamp(),
      'capabilities': _capabilitiesForRole(),
      if (localIp != null) 'localIp': localIp,
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
    final generation = _roomGeneration;
    unawaited(
      refreshDesktopSnapshot(publishChanges: publishChanges).whenComplete(() {
        if (_disposed || _roomGeneration != generation) return;

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
    _stopPhoneFileServer();
    _heartbeatTimer?.cancel();
    _desktopPollTimer?.cancel();
    _presenceCheckTimer?.cancel();
    _stopClipboardPolling();
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
      if (device.role == targetRole && device.id != deviceId) return device;
    }
    for (final device in devices) {
      if (device.role == targetRole) return device;
    }
    return null;
  }

  Map<String, bool> _capabilitiesForRole() {
    return switch (role) {
      DeviceRole.laptop => {
        'media': true,
        'volume': true,
        'lock': true,
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
      'laptop.refresh' => 'refresh laptop',
      'phone.ring' => 'locate phone',
      'phone.stopRing' => 'stop ringing',
      'phone.lock' => 'lock phone',
      'phone.requestAdmin' => 'enable phone lock',
      _ => type,
    };
  }

  Future<void> openReceivedFile(String fullPath) async {
    final file = File(fullPath);
    if (!await file.exists()) {
      statusMessage = 'File not found: $fullPath';
      _safeNotify();
      return;
    }
    await platform.openFile(fullPath);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_cancelRoomSubscriptions());
    super.dispose();
  }

  String get _downloadsDir {
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Public';
      return '$profile\\Downloads\\Connector';
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/Downloads/Connector';
  }

  Future<void> _downloadFileToLaptop(String url, String fileName) async {
    try {
      final directory = Directory(_downloadsDir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await client
            .send(request)
            .timeout(const Duration(minutes: 5));

        if (response.statusCode == 200) {
          final sink = file.openWrite();
          await response.stream.pipe(sink);
          await sink.flush();
          await sink.close();
          statusMessage = 'Received file: $fileName';
          receivedFiles = [file.path, ...receivedFiles.take(19)];
          unawaited(
            platform.showSystemNotification(
              title: 'File received',
              body: fileName,
            ),
          );
          unawaited(
            _publishEvent(
              type: 'file.received',
              title: 'File received',
              detail: fileName,
            ),
          );
        } else {
          statusMessage =
              'Failed to download file (Error: ${response.statusCode})';
        }
      } finally {
        client.close();
      }
    } catch (e) {
      statusMessage = 'Download error: $e';
    }
    _safeNotify();
  }

  String get _phoneDownloadsDir {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download/Connector');
      if (dir.existsSync()) return dir.path;
      final fallback = Directory('${Platform.environment['HOME'] ?? '/tmp'}/Download/Connector');
      if (fallback.existsSync()) return fallback.path;
      return '/storage/emulated/0/Download/Connector';
    }
    return _downloadsDir;
  }

  void _startPhoneFileServer() {
    _stopPhoneFileServer();
    ServerSocket.bind(InternetAddress.anyIPv4, LocalNetworkClient.kPhonePort)
        .then((server) {
      _phoneFileServer = server;
      server.listen((socket) {
        _handlePhoneFileClient(socket);
      });
    }).catchError((_) {});
  }

  void _stopPhoneFileServer() {
    _phoneFileServer?.close();
    _phoneFileServer = null;
  }

  void _handlePhoneFileClient(Socket socket) {
    final bb = BytesBuilder();
    String? fileName;
    int fileSize = 0;
    int headerEnd = -1;
    bool headerParsed = false;
    RandomAccessFile? sink;
    int written = 0;

    socket.listen(
      (data) {
        bb.add(data);

        if (!headerParsed) {
          final buf = bb.toBytes();
          int nlCount = 0;
          for (int i = 0; i < buf.length; i++) {
            if (buf[i] == 10) {
              nlCount++;
              if (nlCount == 2) {
                headerEnd = i + 1;
                break;
              }
            }
          }
          if (headerEnd < 0) return;

          final ascii = String.fromCharCodes(buf);
          final lines = ascii.split('\n');
          if (lines.length < 2 || lines[0].trim() != 'sendFile') {
            socket.close();
            return;
          }
          final parts = lines[1].trim().split('|');
          if (parts.length != 2) { socket.close(); return; }
          final sz = int.tryParse(parts[1]) ?? -1;
          if (sz <= 0) { socket.close(); return; }

          fileName = parts[0];
          fileSize = sz;
          headerParsed = true;

          final dir = Directory(_phoneDownloadsDir);
          if (!dir.existsSync()) dir.createSync(recursive: true);
          sink = File('${dir.path}${Platform.pathSeparator}$fileName')
              .openSync(mode: FileMode.write);
        }

        final buf = bb.toBytes();
        if (headerEnd >= buf.length || sink == null) return;

        final fileData = buf.sublist(headerEnd);
        final needed = fileSize - written;
        final toWrite = fileData.length > needed ? fileData.sublist(0, needed) : fileData;
        if (toWrite.isNotEmpty) {
          sink!.writeFromSync(toWrite);
          written += toWrite.length;
        }
        bb.clear();

        if (written >= fileSize) {
          final fullPath = '$_phoneDownloadsDir${Platform.pathSeparator}$fileName';
          sink!.closeSync();
          socket.close();
          phoneReceivedFiles = [fullPath, ...phoneReceivedFiles.take(19)];
          statusMessage = 'Received file: $fileName';
          unawaited(_publishEvent(
            type: 'file.received',
            title: 'File received from laptop',
            detail: fileName!,
          ));
          _safeNotify();
        }
      },
      onDone: () {
        sink?.closeSync();
        socket.close();
      },
      onError: (_) {
        sink?.closeSync();
        socket.close();
      },
      cancelOnError: false,
    );
  }

  Future<bool> sendFileToPhone(File file) async {
    final sizeInMb = (await file.length()) / (1024 * 1024);

    if (isWifiReachable) {
      final phone = primaryPhone;
      if (phone?.localIp != null) {
        uploadProgress = null;
        _safeNotify();
        final success = await _localClient.sendFileToPhone(phone!.localIp!, file);
        if (success) {
          statusMessage = 'File sent to phone via Local WiFi!';
          _safeNotify();
          return true;
        }
      }
    }

    if (sizeInMb <= maxCloudUploadSize) {
      return await _uploadFileToCloudPhone(file);
    } else {
      statusMessage = 'File too large for Cloud! Connect to WiFi.';
      _safeNotify();
      return false;
    }
  }

  Future<bool> _uploadFileToCloudPhone(File file) async {
    try {
      if (roomCode == null) return false;

      final fileName = file.path.split(Platform.pathSeparator).last;
      final ref = FirebaseStorage.instance.ref().child(
        'uploads/$roomCode/$deviceId/$fileName',
      );

      uploadProgress = 0;
      uploadCurrent = 1;
      uploadTotal = 1;
      _safeNotify();

      final task = ref.putFile(file);
      task.snapshotEvents.listen((snap) {
        if (snap.totalBytes > 0) {
          uploadProgress = snap.bytesTransferred / snap.totalBytes;
          statusMessage = 'Uploading $fileName ${(uploadProgress! * 100).toStringAsFixed(0)}%';
          _safeNotify();
        }
      });

      await task;
      final url = await ref.getDownloadURL();

      uploadProgress = null;
      _safeNotify();

      await sendCommand(
        DeviceRole.phone,
        'phone.receiveFile',
        payload: {'url': url, 'fileName': fileName},
      );

      statusMessage = 'File uploaded to Cloud!';
      _safeNotify();
      return true;
    } catch (e) {
      uploadProgress = null;
      statusMessage = 'Cloud upload to phone failed: $e';
      _safeNotify();
      return false;
    }
  }

  Future<void> _downloadFileToPhone(String url, String fileName) async {
    try {
      final directory = Directory(_phoneDownloadsDir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await client
            .send(request)
            .timeout(const Duration(minutes: 5));

        if (response.statusCode == 200) {
          final sink = file.openWrite();
          await response.stream.pipe(sink);
          await sink.flush();
          await sink.close();
          statusMessage = 'Received file: $fileName';
          phoneReceivedFiles = [file.path, ...phoneReceivedFiles.take(19)];
          unawaited(
            platform.showSystemNotification(
              title: 'File received',
              body: fileName,
            ),
          );
          unawaited(
            _publishEvent(
              type: 'file.received',
              title: 'File received on phone',
              detail: fileName,
            ),
          );
        } else {
          statusMessage =
              'Failed to download file (Error: ${response.statusCode})';
        }
      } finally {
        client.close();
      }
    } catch (e) {
      statusMessage = 'Download error: $e';
    }
    _safeNotify();
  }
}
