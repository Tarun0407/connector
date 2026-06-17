import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'connector_controller.dart';
import 'models.dart';
import 'theme_extensions.dart';

class ConnectorApp extends StatelessWidget {
  const ConnectorApp({super.key, required this.controller});

  final ConnectorController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Connector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF146C94),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F8FB),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
        extensions: <ThemeExtension<dynamic>>[
          const ConnectorColors(
            scaffoldBackground: Color(0xFFF6F8FB),
            cardBorder: Color(0xFFE2E8F0),
            bodyText: Color(0xFF64748B),
            firebaseWarningBackground: Color(0xFFFFFBEB),
            firebaseWarningIcon: Color(0xFFB45309),
            firebaseWarningText: Color(0xFF78350F),
            disconnectedPanelBackground: Color(0xFFE0F2FE),
            statusPillBorder: Color(0xFFD8E0EA),
            onlineIcon: Color(0xFF0F766E),
            emptyStateIcon: Color(0xFF94A3B8),
          ),
        ],
      ),
      home: ConnectorHome(controller: controller),
    );
  }
}

class ConnectorHome extends StatefulWidget {
  const ConnectorHome({super.key, required this.controller});
  final ConnectorController controller;

  @override
  State<ConnectorHome> createState() => _ConnectorHomeState();
}

class _ConnectorHomeState extends State<ConnectorHome> {
  late final TextEditingController _roomController;
  bool _editingPairing = false;

  ConnectorController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _roomController = TextEditingController();
    controller.addListener(_syncRoomCode);
    controller.start();
  }

  @override
  void dispose() {
    controller.removeListener(_syncRoomCode);
    _roomController.dispose();
    super.dispose();
  }

  void _syncRoomCode() {
    final code = controller.roomCode ?? '';
    if (code.isNotEmpty && _roomController.text.isEmpty) {
      _roomController.text = code;
    }
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _SettingsSheet(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 980;
                return SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 32 : 16,
                    vertical: 20,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _TopBar(controller: controller),
                          const SizedBox(height: 16),
                          if (_editingPairing ||
                              !controller.hasRoom ||
                              controller.firebaseError != null)
                            _PairingPanel(
                              controller: controller,
                              textController: _roomController,
                              onSettings: _openSettings,
                              onDone: () =>
                                  setState(() => _editingPairing = false),
                            )
                          else
                            _RememberedPairingPanel(
                              controller: controller,
                              onSettings: _openSettings,
                              onChange: () =>
                                  setState(() => _editingPairing = true),
                            ),
                          if (controller.firebaseError != null) ...[
                            const SizedBox(height: 12),
                            _FirebaseWarning(error: controller.firebaseError!),
                          ],
                          const SizedBox(height: 18),
                          if (controller.role == DeviceRole.laptop)
                            _LaptopHome(controller: controller, wide: wide)
                          else
                            _PhoneHome(controller: controller, wide: wide),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller});

  final ConnectorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = Theme.of(context).extension<ConnectorColors>()!;

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.hub_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connector',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              Text(
                controller.statusMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.bodyText,
                ),
              ),
            ],
          ),
        ),
        _StatusPill(
          icon: controller.currentMode == ConnectivityMode.wifi
              ? Icons.wifi_rounded
              : Icons.language_rounded,
          label: controller.currentMode.label,
        ),
        const SizedBox(width: 8),
        _StatusPill(
          icon: controller.role == DeviceRole.laptop
              ? Icons.computer_rounded
              : Icons.phone_android_rounded,
          label: controller.role.label,
        ),
      ],
    );
  }
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({
    required this.controller,
    required this.textController,
    required this.onSettings,
    required this.onDone,
  });
  final ConnectorController controller;
  final TextEditingController textController;
  final VoidCallback onSettings;
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 260,
              child: TextField(
                controller: textController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  prefixIcon: Icon(Icons.vpn_key_rounded),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (value) async {
                  await controller.joinRoom(value);
                  onDone();
                },
              ),
            ),
            FilledButton.icon(
              onPressed: controller.isBooting
                  ? null
                  : () async {
                      await controller.joinRoom(textController.text);
                      onDone();
                    },
              icon: const Icon(Icons.link_rounded),
              label: const Text('Join'),
            ),
            IconButton.filledTonal(
              onPressed: controller.isBooting
                  ? null
                  : () async {
                      await controller.generateNewRoom();
                      textController.text = controller.roomCode ?? '';
                      onDone();
                    },
              tooltip: 'New code',
              icon: const Icon(Icons.refresh_rounded),
            ),
            _StatusPill(
              icon: controller.firebaseReady
                  ? Icons.cloud_done_rounded
                  : Icons.cloud_off_rounded,
              label: controller.firebaseReady ? 'Firebase ready' : 'Offline',
            ),
            IconButton.filledTonal(
              onPressed: onSettings,
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.controller});

  final ConnectorController controller;
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Wrap(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.vpn_key_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Pairing code'),
                              const SizedBox(height: 6),
                              AnimatedBuilder(
                                animation: c,
                                builder: (context, child) {
                                  return Text(
                                    c.roomCode ?? '',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 1.2,
                                        ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: c.roomCode ?? ''),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Pairing code copied'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy_rounded),
                        ),
                        const SizedBox(width: 8),
                        AnimatedBuilder(
                          animation: c,
                          builder: (context, child) {
                            return IconButton.filledTonal(
                              onPressed: c.isBooting
                                  ? null
                                  : () async {
                                      await c.generateNewRoom();
                                    },
                              icon: const Icon(Icons.refresh_rounded),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedBuilder(
                  animation: c,
                  builder: (context, child) {
                    return SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: c.currentMode == ConnectivityMode.wifi,
                      onChanged: (v) {
                        c.setConnectivityMode(
                          v ? ConnectivityMode.wifi : ConnectivityMode.net,
                        );
                      },
                      secondary: const Icon(Icons.settings_ethernet_rounded),
                      title: const Text('Priority: Local WiFi'),
                      subtitle: Text(
                        c.currentMode == ConnectivityMode.wifi
                            ? 'Tries Local WiFi first, then Cloud'
                            : 'Uses Cloud Server directly',
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: c,
                  builder: (context, child) {
                    return SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: c.autoStartEnabled,
                      onChanged: (v) => c.setAutoStart(v),
                      secondary: const Icon(Icons.rocket_launch_rounded),
                      title: const Text('Autostart'),
                      subtitle: Text(
                        c.autoStartEnabled ? 'Enabled' : 'Disabled',
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                if (c.role == DeviceRole.phone) ...[
                  AnimatedBuilder(
                    animation: c,
                    builder: (context, child) {
                      return FilledButton(
                        onPressed: () async {
                          await c.requestNotificationSendingPermission();
                        },
                        child: const Text('Request notification permission'),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  AnimatedBuilder(
                    animation: c,
                    builder: (context, child) {
                      return FilledButton(
                        onPressed: () async {
                          await c.openNotificationAccessSettings();
                        },
                        child: const Text('Open notification access settings'),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  AnimatedBuilder(
                    animation: c,
                    builder: (context, child) {
                      return FilledButton(
                        onPressed: () async {
                          await c.requestPhoneAdminLocally();
                        },
                        child: const Text('Request device admin'),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  AnimatedBuilder(
                    animation: c,
                    builder: (context, child) {
                      return FilledButton(
                        onPressed: () async {
                          await c.refreshPhoneState();
                        },
                        child: const Text('Refresh phone state'),
                      );
                    },
                  ),
                ] else ...[
                  AnimatedBuilder(
                    animation: c,
                    builder: (context, child) {
                      return FilledButton(
                        onPressed: () async {
                          await c.refreshDesktopSnapshot(publishChanges: true);
                        },
                        child: const Text('Refresh desktop snapshot'),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RememberedPairingPanel extends StatelessWidget {
  const _RememberedPairingPanel({
    required this.controller,
    required this.onSettings,
    required this.onChange,
  });

  final ConnectorController controller;
  final VoidCallback onSettings;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.vpn_key_rounded),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                controller.roomCode ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            _StatusPill(
              icon: controller.firebaseReady
                  ? Icons.cloud_done_rounded
                  : Icons.cloud_off_rounded,
              label: controller.firebaseReady ? 'Connected' : 'Offline',
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: onChange,
              tooltip: 'Change code',
              icon: const Icon(Icons.edit_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: onSettings,
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _FirebaseWarning extends StatelessWidget {
  const _FirebaseWarning({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<ConnectorColors>()!;

    return Card(
      color: colors.firebaseWarningBackground,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: colors.firebaseWarningIcon,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Firebase is not configured yet. Replace lib/firebase_options.dart after creating the Firebase project. $error',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.firebaseWarningText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LaptopHome extends StatelessWidget {
  const _LaptopHome({required this.controller, required this.wide});

  final ConnectorController controller;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final phone = controller.primaryPhone;
    final phoneOnline = phone != null && controller.isDeviceOnline(phone);
    final children = [
      _Panel(
        title: 'Phone Controls',
        icon: Icons.phone_iphone_rounded,
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _CommandButton(
              icon: Icons.ring_volume_rounded,
              label: 'Locate',
              onPressed: () => controller.sendPhoneCommand('phone.ring'),
            ),
            _CommandButton(
              icon: Icons.notifications_off_rounded,
              label: 'Stop',
              onPressed: () => controller.sendPhoneCommand('phone.stopRing'),
            ),
            _CommandButton(
              icon: Icons.lock_rounded,
              label: 'Lock',
              onPressed: () => controller.sendPhoneCommand('phone.lock'),
            ),
            _CommandButton(
              icon: Icons.admin_panel_settings_rounded,
              label: 'Admin',
              onPressed: () =>
                  controller.sendPhoneCommand('phone.requestAdmin'),
            ),
          ],
        ),
      ),
      _Panel(
        title: 'Phone Status',
        icon: Icons.sensors_rounded,
        child: phone == null
            ? const _EmptyState(
                icon: Icons.phone_disabled_rounded,
                label: 'No phone paired',
              )
            : _DeviceSummary(device: phone, online: phoneOnline),
      ),
      _Panel(
        title: 'Recent Activity',
        icon: Icons.receipt_long_rounded,
        child: _ActivityList(events: controller.events.take(8).toList()),
      ),
      _Panel(
        title: 'Startup',
        icon: Icons.power_settings_new_rounded,
        child: _AutoStartSwitch(controller: controller),
      ),
    ];

    return _ResponsiveGrid(wide: wide, children: children);
  }
}

class _PhoneHome extends StatelessWidget {
  const _PhoneHome({required this.controller, required this.wide});

  final ConnectorController controller;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final laptop = controller.primaryLaptop;
    final laptopOnline = laptop != null && controller.isDeviceOnline(laptop);

    final children = [
      if (laptopOnline)
        _LaptopControls(controller: controller, laptop: laptop)
      else
        const _DisconnectedPanel(
          title: 'Laptop disconnected',
          message: 'Controls will appear when your laptop reconnects.',
          icon: Icons.laptop_chromebook_rounded,
        ),
      _Panel(
        title: 'Activity Log',
        icon: Icons.history_rounded,
        child: _ActivityList(events: controller.events),
      ),
      _Panel(
        title: 'Paired Devices',
        icon: Icons.devices_rounded,
        child: _DeviceList(controller: controller, devices: controller.devices),
      ),
      _Panel(
        title: 'This Phone',
        icon: Icons.phone_android_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _StatusPill(
                  icon: controller.phoneAdminEnabled
                      ? Icons.verified_user_rounded
                      : Icons.no_encryption_rounded,
                  label: controller.phoneAdminEnabled
                      ? 'Admin on'
                      : 'Admin off',
                ),
                _CommandButton(
                  icon: Icons.admin_panel_settings_rounded,
                  label: 'Enable',
                  onPressed: controller.requestPhoneAdminLocally,
                ),
                _CommandButton(
                  icon: Icons.notifications_off_rounded,
                  label: 'Stop ring',
                  onPressed: () => controller.platform.stopRingPhone(),
                ),
                _StatusPill(
                  icon: controller.canPostNotifications
                      ? Icons.notification_important_rounded
                      : Icons.notifications_none_rounded,
                  label: controller.canPostNotifications
                      ? 'Notify on'
                      : 'Notify off',
                ),
                _CommandButton(
                  icon: Icons.add_alert_rounded,
                  label: 'Allow notify',
                  onPressed: controller.requestNotificationSendingPermission,
                ),
                _StatusPill(
                  icon: controller.notificationAccessEnabled
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_paused_rounded,
                  label: controller.notificationAccessEnabled
                      ? 'Mirror on'
                      : 'Mirror off',
                ),
                _CommandButton(
                  icon: Icons.notification_add_rounded,
                  label: 'Mirror',
                  onPressed: controller.openNotificationAccessSettings,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _AutoStartSwitch(controller: controller),
          ],
        ),
      ),
    ];

    return _ResponsiveGrid(wide: wide, children: children);
  }
}

class _DisconnectedPanel extends StatelessWidget {
  const _DisconnectedPanel({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<ConnectorColors>()!;

    return _Panel(
      title: title,
      icon: Icons.link_off_rounded,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: colors.disconnectedPanelBackground,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                icon,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Device disconnected',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.bodyText),
            ),
          ],
        ),
      ),
    );
  }
}

class _LaptopControls extends StatefulWidget {
  const _LaptopControls({required this.controller, required this.laptop});
  final ConnectorController controller;
  final RemoteDevice? laptop;

  @override
  State<_LaptopControls> createState() => _LaptopControlsState();
}

class _LaptopControlsState extends State<_LaptopControls> {
  double? _pendingVolume;
  Timer? _debounceTimer;
  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onVolumeChanged(double value) {
    setState(() => _pendingVolume = value);

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      if (mounted) {
        await widget.controller.sendLaptopCommand(
          'laptop.volume.set',
          payload: {'level': value.round()},
        );
        setState(() => _pendingVolume = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final laptop = widget.laptop;
    final remoteVolume = laptop?.volume ?? widget.controller.laptopVolume ?? 50;
    final volume = (_pendingVolume ?? remoteVolume).clamp(0, 100).toDouble();
    return _Panel(
      title: 'Laptop Controls',
      icon: Icons.laptop_windows_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _CommandButton(
                icon: Icons.skip_previous_rounded,
                label: 'Prev',
                onPressed: () => widget.controller.sendLaptopCommand(
                  'laptop.media.previous',
                ),
              ),
              _CommandButton(
                icon: Icons.play_arrow_rounded,
                label: 'Play',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.media.toggle'),
              ),
              _CommandButton(
                icon: Icons.skip_next_rounded,
                label: 'Next',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.media.next'),
              ),
              _CommandButton(
                icon: Icons.volume_down_rounded,
                label: 'Down',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.volume.down'),
              ),
              _CommandButton(
                icon: Icons.volume_off_rounded,
                label: 'Mute',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.volume.mute'),
              ),
              _CommandButton(
                icon: Icons.volume_up_rounded,
                label: 'Up',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.volume.up'),
              ),
              _CommandButton(
                icon: Icons.lock_rounded,
                label: 'Lock',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.lock'),
              ),
              _CommandButton(
                icon: Icons.sync_rounded,
                label: 'Refresh',
                onPressed: () =>
                    widget.controller.sendLaptopCommand('laptop.refresh'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.volume_up_rounded, size: 22),
              Expanded(
                child: Slider(
                  value: volume,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${volume.round()}%',
                  onChanged: _onVolumeChanged,
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${volume.round()}%',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
          if (laptop == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _EmptyState(
                icon: Icons.laptop_chromebook_rounded,
                label: 'No laptop paired',
              ),
            ),
        ],
      ),
    );
  }
}

class _ResponsiveGrid extends StatelessWidget {
  const _ResponsiveGrid({required this.wide, required this.children});

  final bool wide;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children) ...[child, const SizedBox(height: 14)],
        ],
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 370.0,
        mainAxisSpacing: 14.0,
        crossAxisSpacing: 14.0,
        childAspectRatio: 0.8,
      ),
      itemCount: children.length,
      itemBuilder: (context, index) {
        return children[index];
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _CommandButton extends StatelessWidget {
  const _CommandButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<ConnectorColors>()!;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.statusPillBorder),
        color: Colors.white,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _AutoStartSwitch extends StatelessWidget {
  const _AutoStartSwitch({required this.controller});

  final ConnectorController controller;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: controller.autoStartEnabled,
      onChanged: controller.setAutoStart,
      secondary: const Icon(Icons.rocket_launch_rounded),
      title: const Text('Autostart'),
      subtitle: Text(controller.autoStartEnabled ? 'Enabled' : 'Disabled'),
    );
  }
}

class _DeviceSummary extends StatelessWidget {
  const _DeviceSummary({required this.device, required this.online});

  final RemoteDevice device;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatusPill(
              icon: online
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              label: online ? 'Online' : 'Offline',
            ),
            _StatusPill(icon: Icons.devices_rounded, label: device.platform),
            if (device.adminEnabled != null)
              _StatusPill(
                icon: device.adminEnabled!
                    ? Icons.verified_user_rounded
                    : Icons.no_encryption_rounded,
                label: device.adminEnabled! ? 'Admin on' : 'Admin off',
              ),
          ],
        ),
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.controller, required this.devices});

  final ConnectorController controller;
  final List<RemoteDevice> devices;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const _EmptyState(
        icon: Icons.devices_other_rounded,
        label: 'No devices online',
      );
    }

    return Column(
      children: [
        for (final device in devices)
          _DeviceListTile(
            device: device,
            online: controller.isDeviceOnline(device),
          ),
      ],
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  const _DeviceListTile({required this.device, required this.online});

  final RemoteDevice device;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<ConnectorColors>()!;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        device.role == DeviceRole.laptop
            ? Icons.computer_rounded
            : Icons.phone_android_rounded,
      ),
      title: Text(device.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(device.platform),
      trailing: Icon(
        online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
        color: online ? colors.onlineIcon : Colors.grey,
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.events});

  final List<ActivityEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const _EmptyState(
        icon: Icons.history_toggle_off_rounded,
        label: 'No activity yet',
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: ListView.separated(
        shrinkWrap: true,
        itemBuilder: (context, index) {
          final event = events[index];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_eventIcon(event.type)),
            title: Text(
              event.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _eventSubtitle(event),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemCount: events.length,
      ),
    );
  }

  IconData _eventIcon(String type) {
    if (type.contains('opened')) {
      return Icons.open_in_new_rounded;
    }
    if (type.contains('closed')) {
      return Icons.close_fullscreen_rounded;
    }
    if (type.contains('failed')) {
      return Icons.error_outline_rounded;
    }
    return Icons.check_circle_outline_rounded;
  }

  String _eventSubtitle(ActivityEvent event) {
    final time = event.originalTime;
    if (time == null || event.type != 'phone.notification') {
      return event.detail;
    }

    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute  ${event.detail}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<ConnectorColors>()!;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: colors.emptyStateIcon),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.bodyText),
            ),
          ],
        ),
      ),
    );
  }
}
