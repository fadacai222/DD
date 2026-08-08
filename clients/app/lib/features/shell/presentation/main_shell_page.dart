import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/data/auth_api_client.dart';
import '../../auth/domain/auth_session.dart';
import '../../auth/presentation/account_management_page.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/domain/call_session.dart';
import '../../calls/presentation/call_debug_controller.dart';
import '../../calls/presentation/chat_call_page.dart';
import '../../calls/presentation/two_party_call_controller.dart';
import '../../contacts/presentation/contacts_page.dart';
import '../../messaging/presentation/conversations_page.dart';

class MainShellPage extends StatefulWidget {
  const MainShellPage({
    super.key,
    required this.origin,
    required this.session,
    required this.authGateway,
    required this.onRefreshSession,
    required this.onLogout,
  });

  final Uri origin;
  final AuthSession session;
  final AuthGateway authGateway;
  final Future<void> Function() onRefreshSession;
  final Future<void> Function() onLogout;

  @override
  State<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends State<MainShellPage> {
  int _index = 0;
  late final CallDebugController _callMediaController;
  late final TwoPartyCallController _callController;
  late final Future<bool> _callStartup;
  bool _callRouteOpen = false;
  int _avatarRevision = 0;
  bool _avatarBusy = false;

  @override
  void initState() {
    super.initState();
    _callMediaController = CallDebugController();
    _callController = TwoPartyCallController(_callMediaController);
    _callController.addListener(_handleCallState);
    _callStartup = _callController.start(
      apiBaseUrl: widget.origin.toString(),
      participantIdentity: widget.session.user.id,
      participantName: widget.session.user.displayName,
    );
  }

  @override
  void dispose() {
    _callController.removeListener(_handleCallState);
    _callController.dispose();
    _callMediaController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 720;
          final pages = _buildPages();
          final pageStack = IndexedStack(index: _index, children: pages);
          if (desktop) {
            return Row(
              children: [
                _DesktopRail(
                  origin: widget.origin,
                  session: widget.session,
                  avatarRevision: _avatarRevision,
                  selectedIndex: _index,
                  onSelected: (value) => setState(() => _index = value),
                  onSettings: _openAccountManagement,
                ),
                const VerticalDivider(width: 1, thickness: 0.5),
                Expanded(child: SafeArea(left: false, child: pageStack)),
              ],
            );
          }
          return SafeArea(
            child: Column(
              children: [
                Expanded(child: pageStack),
                NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (value) =>
                      setState(() => _index = value),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.chat_bubble_outline_rounded),
                      selectedIcon: Icon(Icons.chat_bubble_rounded),
                      label: '消息',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.people_outline_rounded),
                      selectedIcon: Icon(Icons.people_rounded),
                      label: '联系人',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore_rounded),
                      label: '发现',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: '我的',
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildPages() {
    final sessionVersion =
        widget.session.tokens.accessExpiresAt.microsecondsSinceEpoch;
    return [
      ConversationsPage(
        key: ValueKey(
          'shell-messages-${widget.session.user.id}-$sessionVersion',
        ),
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        currentUserId: widget.session.user.id,
        deviceId: widget.session.device.id,
        currentUserDisplayName: widget.session.user.displayName,
        currentUserAvatarRevision: _avatarRevision,
        onStartCall: _startCall,
        onOpenContacts: () => setState(() => _index = 1),
        embedded: true,
      ),
      ContactsPage(
        key: ValueKey(
          'shell-contacts-${widget.session.user.id}-$sessionVersion',
        ),
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        currentUserId: widget.session.user.id,
        embedded: true,
      ),
      const _DiscoveryPage(),
      _MePage(
        origin: widget.origin,
        session: widget.session,
        avatarRevision: _avatarRevision,
        avatarBusy: _avatarBusy,
        onChangeAvatar: _changeAvatar,
        onRemoveAvatar: _removeAvatar,
        onRefresh: widget.onRefreshSession,
        onOpenSettings: _openAccountManagement,
        onLogout: widget.onLogout,
      ),
    ];
  }

  void _handleCallState() {
    final call = _callController.currentCall;
    if (call == null ||
        !call.isIncomingFor(widget.session.user.id) ||
        _callRouteOpen ||
        !mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _callRouteOpen) return;
      unawaited(_openCallPage(call.callerName));
    });
  }

  Future<void> _startCall(String peerId, String peerName, CallKind kind) async {
    final ready = await _callStartup;
    if (!mounted) return;
    if (!ready || !_callController.signalingConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_callController.errorMessage ?? '通话服务尚未连接，请稍后再试。'),
        ),
      );
      return;
    }
    if (_callController.currentCall?.isActive == true) {
      await _openCallPage(peerName);
      return;
    }
    await _callController.placeCall(calleeIdentity: peerId, kind: kind);
    if (!mounted) return;
    if (_callController.currentCall == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_callController.errorMessage ?? '无法发起通话。')),
      );
      return;
    }
    await _openCallPage(peerName);
  }

  Future<void> _openCallPage(String peerName) async {
    if (_callRouteOpen || !mounted) return;
    _callRouteOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ChatCallPage(
            controller: _callController,
            mediaController: _callMediaController,
            peerName: peerName,
          ),
        ),
      );
    } finally {
      _callRouteOpen = false;
    }
  }

  Future<void> _changeAvatar() async {
    if (_avatarBusy) return;
    const imageGroup = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
    );
    final file = await openFile(acceptedTypeGroups: const [imageGroup]);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像必须小于 2 MiB。')));
      return;
    }
    final contentType =
        file.mimeType?.split(';').first.trim().toLowerCase() ??
        _avatarContentType(file.name);
    if (contentType == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('只支持 JPEG、PNG、WebP 头像。')));
      return;
    }
    setState(() => _avatarBusy = true);
    try {
      final updatedAt = await widget.authGateway.uploadProfileAvatar(
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        bytes: bytes,
        contentType: contentType,
      );
      ProfileAvatar.evict(widget.origin, widget.session.user.id);
      if (!mounted) return;
      setState(() => _avatarRevision = updatedAt.microsecondsSinceEpoch);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像已更新')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('头像更新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _removeAvatar() async {
    if (_avatarBusy) return;
    setState(() => _avatarBusy = true);
    try {
      await widget.authGateway.deleteProfileAvatar(
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
      );
      ProfileAvatar.evict(widget.origin, widget.session.user.id);
      if (!mounted) return;
      setState(() => _avatarRevision = DateTime.now().microsecondsSinceEpoch);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像已移除')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移除头像失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  String? _avatarContentType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return null;
  }

  Future<void> _openAccountManagement() async {
    final logout = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AccountManagementPage(
          gateway: widget.authGateway,
          origin: widget.origin,
          session: widget.session,
        ),
      ),
    );
    if (logout == true && mounted) {
      await widget.onLogout();
    }
  }
}

class _DesktopRail extends StatelessWidget {
  const _DesktopRail({
    required this.origin,
    required this.session,
    required this.avatarRevision,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSettings,
  });

  final Uri origin;
  final AuthSession session;
  final int avatarRevision;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      color: DdColors.desktopRail,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 14),
            Tooltip(
              message: session.user.displayName,
              child: _RailAvatar(
                origin: origin,
                accessToken: session.tokens.accessToken,
                userId: session.user.id,
                name: session.user.displayName,
                revision: avatarRevision,
              ),
            ),
            const SizedBox(height: 24),
            _RailButton(
              key: const Key('shell-rail-messages'),
              icon: Icons.chat_bubble_outline_rounded,
              selectedIcon: Icons.chat_bubble_rounded,
              label: '消息',
              selected: selectedIndex == 0,
              onTap: () => onSelected(0),
            ),
            _RailButton(
              key: const Key('shell-rail-contacts'),
              icon: Icons.people_outline_rounded,
              selectedIcon: Icons.people_rounded,
              label: '联系人',
              selected: selectedIndex == 1,
              onTap: () => onSelected(1),
            ),
            _RailButton(
              key: const Key('shell-rail-discovery'),
              icon: Icons.explore_outlined,
              selectedIcon: Icons.explore_rounded,
              label: '发现',
              selected: selectedIndex == 2,
              onTap: () => onSelected(2),
            ),
            const Spacer(),
            _RailButton(
              key: const Key('shell-rail-me'),
              icon: Icons.person_outline_rounded,
              selectedIcon: Icons.person_rounded,
              label: '我的',
              selected: selectedIndex == 3,
              onTap: () => onSelected(3),
            ),
            _RailButton(
              key: const Key('shell-rail-settings'),
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings_rounded,
              label: '设置',
              selected: false,
              onTap: onSettings,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 450),
      child: SizedBox(
        width: 60,
        height: 52,
        child: InkWell(
          onTap: onTap,
          child: Icon(
            selected ? selectedIcon : icon,
            size: 25,
            color: selected ? DdColors.green : const Color(0xFFA4A4A4),
          ),
        ),
      ),
    );
  }
}

class _RailAvatar extends StatelessWidget {
  const _RailAvatar({
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.name,
    this.revision = 0,
    this.size = 38,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String name;
  final int revision;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ProfileAvatar(
      origin: origin,
      accessToken: accessToken,
      userId: userId,
      displayName: name,
      revision: revision,
      size: size,
      fallbackColor: const Color(0xFF6EBB5A),
    );
  }
}

class _DiscoveryPage extends StatelessWidget {
  const _DiscoveryPage();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          _SimpleHeader(title: '发现'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 10),
              children: const [
                _FeatureRow(
                  icon: Icons.camera_alt_outlined,
                  label: '朋友圈',
                  trailing: 'P8 开发阶段接入',
                ),
                SizedBox(height: 8),
                _FeatureRow(
                  icon: Icons.qr_code_scanner_rounded,
                  label: '扫一扫',
                  trailing: 'P9 开发阶段接入',
                ),
                SizedBox(height: 8),
                _FeatureRow(
                  icon: Icons.widgets_outlined,
                  label: '更多能力',
                  trailing: '按路线逐步开放',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.label,
    required this.trailing,
  });

  final IconData icon;
  final String label;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 58,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: DdColors.greenPressed, size: 23),
              const SizedBox(width: 16),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 15)),
              ),
              Text(
                trailing,
                style: const TextStyle(
                  fontSize: 11,
                  color: DdColors.textTertiary,
                ),
              ),
              const SizedBox(width: 5),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: DdColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MePage extends StatelessWidget {
  const _MePage({
    required this.origin,
    required this.session,
    required this.avatarRevision,
    required this.avatarBusy,
    required this.onChangeAvatar,
    required this.onRemoveAvatar,
    required this.onRefresh,
    required this.onOpenSettings,
    required this.onLogout,
  });

  final Uri origin;
  final AuthSession session;
  final int avatarRevision;
  final bool avatarBusy;
  final Future<void> Function() onChangeAvatar;
  final Future<void> Function() onRemoveAvatar;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenSettings;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          const _SimpleHeader(title: '我的'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 10, bottom: 18),
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
                    child: Row(
                      children: [
                        PopupMenuButton<String>(
                          tooltip: '头像',
                          onSelected: (value) {
                            if (value == 'change') {
                              unawaited(onChangeAvatar());
                            } else if (value == 'remove') {
                              unawaited(onRemoveAvatar());
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'change', child: Text('更换头像')),
                            PopupMenuItem(value: 'remove', child: Text('移除头像')),
                          ],
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              _RailAvatar(
                                origin: origin,
                                accessToken: session.tokens.accessToken,
                                userId: session.user.id,
                                name: session.user.displayName,
                                revision: avatarRevision,
                                size: 58,
                              ),
                              if (avatarBusy)
                                Container(
                                  width: 58,
                                  height: 58,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.38),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  alignment: Alignment.center,
                                  child: const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                session.user.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                'DD号：${session.user.handle}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: DdColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.qr_code_2_rounded,
                          size: 22,
                          color: DdColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingsRow(
                  key: const Key('shell-account-management'),
                  icon: Icons.manage_accounts_outlined,
                  label: '账号、隐私与设备',
                  onTap: onOpenSettings,
                ),
                _SettingsRow(
                  key: const Key('auth-refresh'),
                  icon: Icons.refresh_rounded,
                  label: '刷新登录会话',
                  onTap: () => onRefresh(),
                ),
                const SizedBox(height: 8),
                _SettingsRow(
                  key: const Key('shell-logout'),
                  icon: Icons.logout_rounded,
                  label: '退出登录',
                  destructive: true,
                  onTap: () => onLogout(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: destructive ? DdColors.danger : DdColors.greenPressed,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: destructive ? DdColors.danger : null,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: DdColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SimpleHeader extends StatelessWidget {
  const _SimpleHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
