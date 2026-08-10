import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/notifications/app_notification_service.dart';
import '../../../core/theme/app_theme_mode_store.dart';
import '../../../theme/app_theme.dart';
import '../../messaging/data/chat_appearance_store.dart';
import '../../messaging/presentation/chat_background_settings_page.dart';
import '../data/auth_api_client.dart';
import '../domain/account_management.dart';
import '../domain/auth_session.dart';

class AccountManagementPage extends StatefulWidget {
  const AccountManagementPage({
    super.key,
    required this.gateway,
    required this.origin,
    required this.session,
  });

  final AuthGateway gateway;
  final Uri origin;
  final AuthSession session;

  @override
  State<AccountManagementPage> createState() => _AccountManagementPageState();
}

class _AccountManagementPageState extends State<AccountManagementPage> {
  AccountMe? _me;
  List<AccountDevice> _devices = const [];
  bool _busy = true;
  bool _allowEmailSearch = false;
  bool _allowStrangerMessages = false;
  bool _showOnlineStatus = true;
  bool _readReceipts = true;
  bool _notificationPreview = true;
  String? _message;
  Timer? _autoSaveTimer;
  int _section = 0;

  String get _accessToken => widget.session.tokens.accessToken;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        toolbarHeight: 46,
        titleSpacing: 18,
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _busy && _me == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 680) {
                    return _desktopSettings();
                  }
                  return _mobileSettings();
                },
              ),
      ),
    );
  }

  Widget _desktopSettings() {
    return Row(
      children: [
        SizedBox(
          width: 164,
          child: ColoredBox(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF252525)
                : const Color(0xFFF4F4F4),
            child: Column(
              children: [
                const SizedBox(height: 8),
                _SettingsNavItem(
                  icon: Icons.person_outline_rounded,
                  label: '账号与存储',
                  selected: _section == 0,
                  onTap: () => setState(() => _section = 0),
                ),
                _SettingsNavItem(
                  icon: Icons.settings_outlined,
                  label: '通用',
                  selected: _section == 1,
                  onTap: () => setState(() => _section = 1),
                ),
                _SettingsNavItem(
                  icon: Icons.keyboard_alt_outlined,
                  label: '快捷键',
                  selected: _section == 2,
                  onTap: () => setState(() => _section = 2),
                ),
                _SettingsNavItem(
                  icon: Icons.notifications_none_rounded,
                  label: '通知',
                  selected: _section == 3,
                  onTap: () => setState(() => _section = 3),
                ),
                _SettingsNavItem(
                  icon: Icons.extension_outlined,
                  label: '插件',
                  selected: _section == 4,
                  onTap: () => setState(() => _section = 4),
                ),
                _SettingsNavItem(
                  icon: Icons.info_outline_rounded,
                  label: '关于 DD',
                  selected: _section == 5,
                  onTap: () => setState(() => _section = 5),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1, thickness: 0.5),
        Expanded(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: _settingsContent(),
          ),
        ),
      ],
    );
  }

  Widget _mobileSettings() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
      children: [
        if (_message != null) _messageBanner(),
        _sectionTitle('通用'),
        _themeModeRow(),
        const Divider(height: 1),
        _chatBackgroundRow(),
        const SizedBox(height: 18),
        _sectionTitle('隐私'),
        _privacySettings(),
        const SizedBox(height: 18),
        _sectionTitle('设备'),
        _deviceSettings(),
      ],
    );
  }

  Widget _settingsContent() {
    final body = switch (_section) {
      0 => _accountAndStorage(),
      1 => _generalSettings(),
      2 => _shortcutSettings(),
      3 => _notificationSettings(),
      4 => _pluginSettings(),
      _ => _aboutSettings(),
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 20, 30, 32),
      children: [
        if (_message != null) ...[_messageBanner(), const SizedBox(height: 14)],
        body,
      ],
    );
  }

  Widget _accountAndStorage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_sectionTitle('登录设备'), _deviceSettings()],
    );
  }

  Widget _generalSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('通用'),
        _themeModeRow(),
        const Divider(height: 1),
        _chatBackgroundRow(),
        const Divider(height: 1),
        _privacySettings(),
      ],
    );
  }

  Widget _themeModeRow() => Material(
    color: Colors.transparent,
    child: InkWell(
      key: const Key('settings-theme-mode'),
      borderRadius: BorderRadius.circular(DdRadii.surface),
      onTap: _chooseThemeMode,
      child: _SettingLine(
        title: '外观',
        subtitle: AppThemeModeStore.shared.label,
        leading: const Icon(
          Icons.brightness_6_outlined,
          size: 20,
          color: DdColors.textSecondary,
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          size: 19,
          color: DdColors.textTertiary,
        ),
      ),
    ),
  );

  Future<void> _chooseThemeMode() async {
    final store = AppThemeModeStore.shared;
    // Opening the appearance chooser must never wait on secure-storage I/O.
    // The app shell loads this preference at startup; an isolated settings
    // page can still show the safe system default immediately.
    unawaited(store.load());
    final selected = await showModalBottomSheet<ThemeMode>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '外观',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          for (final option in const <(ThemeMode, String, IconData)>[
            (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
            (ThemeMode.light, '浅色', Icons.light_mode_outlined),
            (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
          ])
            ListTile(
              key: Key('theme-mode-${option.$1.name}'),
              leading: Icon(option.$3),
              title: Text(option.$2),
              trailing: store.mode == option.$1
                  ? const Icon(Icons.check_rounded, color: DdColors.green)
                  : null,
              onTap: () => Navigator.pop(sheetContext, option.$1),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (selected == null || selected == store.mode) return;
    try {
      await store.setMode(selected);
      if (mounted) setState(() => _message = null);
    } catch (_) {
      if (mounted) setState(() => _message = '外观设置保存失败，请重试。');
    }
  }

  Widget _chatBackgroundRow() => Material(
    color: Colors.transparent,
    child: InkWell(
      key: const Key('settings-chat-background'),
      borderRadius: BorderRadius.circular(DdRadii.surface),
      onTap: _openChatBackground,
      child: const _SettingLine(
        title: '聊天背景',
        subtitle: '设置所有聊天默认使用的背景',
        leading: Icon(
          Icons.wallpaper_rounded,
          size: 20,
          color: DdColors.textSecondary,
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          size: 19,
          color: DdColors.textTertiary,
        ),
      ),
    ),
  );

  Future<void> _openChatBackground() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatBackgroundSettingsPage(
          store: ChatAppearanceStore.shared(widget.session.user.id),
        ),
      ),
    );
  }

  Widget _shortcutSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        _DesktopSectionHeading('快捷键'),
        _SettingLine(
          title: '发送消息',
          subtitle: '默认桌面键盘行为',
          trailing: _ShortcutKey('Enter'),
        ),
        Divider(height: 1),
        _SettingLine(
          title: '消息内换行',
          subtitle: '输入多行文本而不发送',
          trailing: _ShortcutKey('Shift + Enter'),
        ),
      ],
    );
  }

  Widget _notificationSettings() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? const Color(0xFF2A2A2A) : const Color(0xFFF6F6F6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DesktopSectionHeading('通知与声音'),
        Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(DdRadii.surface),
          ),
          child: Column(
            children: [
              _SwitchSettingLine(
                title: '消息预览',
                subtitle: '在通知里显示发送者和消息正文',
                value: _notificationPreview,
                enabled: !_busy,
                onChanged: (value) {
                  setState(() => _notificationPreview = value);
                  _scheduleAutoSave();
                },
              ),
              const Divider(height: 1, indent: 56),
              const _SettingLine(
                title: '桌面弹窗',
                subtitle: '使用 DD 自定义浮层，显示发送者头像和消息内容',
                trailing: Text(
                  'DD 样式',
                  style: TextStyle(color: DdColors.greenPressed, fontSize: 12),
                ),
              ),
              const Divider(height: 1, indent: 56),
              const _SettingLine(
                title: '系统通知回退',
                subtitle: '仅当 DD 自定义弹窗不可用时回退 Windows 系统通知',
                trailing: Text(
                  '自动',
                  style: TextStyle(color: DdColors.textSecondary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const _DesktopSectionHeading('会话通知'),
        Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(DdRadii.surface),
          ),
          child: const Column(
            children: [
              _SettingLine(title: '会话免打扰', subtitle: '在会话列表右键可设置 8 小时或 7 天免打扰'),
              Divider(height: 1, indent: 56),
              _SettingLine(
                title: '前台消息',
                subtitle: '软件处于前台时使用顶部轻量通知，不弹 Windows 系统通知',
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const _DesktopSectionHeading('预览与诊断'),
        Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(DdRadii.surface),
          ),
          child: Column(
            children: [
              _SettingLine(
                title: '测试桌面通知',
                subtitle: '立即发送一条带头像的 DD 通知，用于检查弹窗样式',
                trailing: TextButton(
                  onPressed: _sendNotificationPreview,
                  child: const Text('测试'),
                ),
              ),
              const Divider(height: 1, indent: 56),
              _SettingLine(
                title: '本地错误日志',
                subtitle: ClientLog.path ?? '当前平台不写本地文件日志',
                trailing: ClientLog.path == null
                    ? null
                    : IconButton(
                        tooltip: '复制日志路径',
                        onPressed: _copyLogPath,
                        icon: const Icon(Icons.copy_rounded, size: 17),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _sendNotificationPreview() async {
    await AppNotificationService.shared.initialize(requestPermission: false);
    await AppNotificationService.shared.showMessage(
      senderName: 'DD 通知预览',
      preview: _notificationPreview ? '这是一条桌面通知预览。' : '你收到了一条新消息',
      conversationId: 'notification-preview',
      origin: widget.origin,
      accessToken: widget.session.tokens.accessToken,
      senderUserId: widget.session.user.id,
    );
  }

  Future<void> _copyLogPath() async {
    final path = ClientLog.path;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('日志路径已复制')));
  }

  Widget _pluginSettings() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DesktopSectionHeading('插件'),
        _SettingLine(
          title: 'GIF Provider',
          subtitle: '第三方 GIF 搜索将采用可关闭 Provider；本地 GIF 不依赖插件',
          trailing: Text(
            '尚未启用',
            style: TextStyle(color: DdColors.textTertiary),
          ),
        ),
        Divider(height: 1),
        _SettingLine(
          title: '机器人 / 扩展 API',
          subtitle: '协议保留扩展能力，不在当前 P4 强行塞入半成品',
          trailing: Text('规划中', style: TextStyle(color: DdColors.textTertiary)),
        ),
      ],
    );
  }

  Widget _aboutSettings() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DesktopSectionHeading('关于 DD'),
        _SettingLine(
          title: 'DD',
          subtitle: '自托管即时通讯 · UI 交互参考微信 · 开放能力参考 Telegram',
          trailing: Text(
            '开发版',
            style: TextStyle(color: DdColors.textSecondary),
          ),
        ),
        Divider(height: 1),
        _SettingLine(title: '设计原则', subtitle: '不以 WhatsApp 为 UI 或交互设计参考'),
      ],
    );
  }

  Widget _privacySettings() {
    return Column(
      children: [
        _SwitchSettingLine(
          title: '允许通过邮箱搜索我',
          value: _allowEmailSearch,
          enabled: !_busy,
          onChanged: (value) {
            setState(() => _allowEmailSearch = value);
            _scheduleAutoSave();
          },
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '显示在线状态',
          value: _showOnlineStatus,
          enabled: !_busy,
          onChanged: (value) {
            setState(() => _showOnlineStatus = value);
            _scheduleAutoSave();
          },
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '已读回执',
          subtitle: '关闭后不会向对方暴露精确已读位置',
          value: _readReceipts,
          enabled: !_busy,
          onChanged: (value) {
            setState(() => _readReceipts = value);
            _scheduleAutoSave();
          },
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '通知显示消息预览',
          value: _notificationPreview,
          enabled: !_busy,
          onChanged: (value) {
            setState(() => _notificationPreview = value);
            _scheduleAutoSave();
          },
        ),
      ],
    );
  }

  Widget _deviceSettings() {
    return Column(
      children: [
        if (_devices.isEmpty)
          const _SettingLine(title: '暂无设备记录')
        else
          for (var index = 0; index < _devices.length; index++) ...[
            _deviceRow(_devices[index]),
            if (index != _devices.length - 1) const Divider(height: 1),
          ],
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _logoutAll,
            icon: const Icon(Icons.phonelink_erase_rounded, size: 18),
            label: const Text('退出全部设备'),
          ),
        ),
      ],
    );
  }

  Widget _deviceRow(AccountDevice device) {
    return _SettingLine(
      title: '${device.name}${device.current ? '（当前设备）' : ''}',
      subtitle:
          '${device.platform} · ${device.appVersion} · 最后活动 ${device.lastSeenAt.toLocal()}${device.revoked ? ' · 已撤销' : ''}',
      leading: Icon(
        device.current ? Icons.computer_rounded : Icons.devices_other_rounded,
        size: 20,
        color: DdColors.textSecondary,
      ),
      trailing: device.revoked
          ? const Text('已退出', style: TextStyle(color: DdColors.textTertiary))
          : TextButton(
              onPressed: _busy ? null : () => _revokeDevice(device),
              child: Text(device.current ? '退出' : '远程退出'),
            ),
    );
  }

  Widget _messageBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF7F1),
        borderRadius: BorderRadius.circular(DdRadii.control),
      ),
      child: Text(
        _message!,
        style: const TextStyle(fontSize: 12, color: Color(0xFF38725B)),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
  );

  Future<void> _load() => _run(() async {
    final me = await widget.gateway.getMe(
      origin: widget.origin,
      accessToken: _accessToken,
    );
    final devices = await widget.gateway.listDevices(
      origin: widget.origin,
      accessToken: _accessToken,
    );
    if (!mounted) return;
    setState(() {
      _me = me;
      _devices = devices;
      _allowEmailSearch = me.privacy.allowEmailSearch;
      _allowStrangerMessages = me.privacy.allowStrangerMessages;
      _showOnlineStatus = me.privacy.showOnlineStatus;
      _readReceipts = me.privacy.readReceiptsEnabled;
      _notificationPreview = me.privacy.notificationPreviewEnabled;
    });
  });

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      if (_busy) {
        _scheduleAutoSave();
        return;
      }
      unawaited(_saveSettings());
    });
  }

  Future<void> _saveSettings() => _run(() async {
    final current = _me;
    if (current == null) return;
    final me = await widget.gateway.updateMe(
      origin: widget.origin,
      accessToken: _accessToken,
      handle: current.profile.handle,
      displayName: current.profile.displayName,
      bio: current.profile.bio,
      privacy: AccountPrivacy(
        allowEmailSearch: _allowEmailSearch,
        allowStrangerMessages: _allowStrangerMessages,
        showOnlineStatus: _showOnlineStatus,
        readReceiptsEnabled: _readReceipts,
        notificationPreviewEnabled: _notificationPreview,
      ),
    );
    if (!mounted) return;
    setState(() {
      _me = me;
      _message = '设置已保存';
    });
  });

  Future<void> _revokeDevice(AccountDevice device) => _run(() async {
    await widget.gateway.revokeDevice(
      origin: widget.origin,
      accessToken: _accessToken,
      deviceId: device.id,
    );
    if (!mounted) return;
    if (device.current) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _message = '设备 ${device.name} 已远程退出。';
      _devices = _devices
          .map(
            (item) => item.id == device.id
                ? AccountDevice(
                    id: item.id,
                    name: item.name,
                    platform: item.platform,
                    appVersion: item.appVersion,
                    createdAt: item.createdAt,
                    lastSeenAt: item.lastSeenAt,
                    current: item.current,
                    revoked: true,
                  )
                : item,
          )
          .toList(growable: false);
    });
  });

  Future<void> _logoutAll() => _run(() async {
    await widget.gateway.logoutAll(
      origin: widget.origin,
      accessToken: _accessToken,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  });

  Future<void> _run(Future<void> Function() action) async {
    if (_busy && _me != null) return;
    if (mounted) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? DdColors.green : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? Colors.white : DdColors.textSecondary,
                ),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? Colors.white : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSectionHeading extends StatelessWidget {
  const _DesktopSectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
  );
}

class _SettingLine extends StatelessWidget {
  const _SettingLine({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 58),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

class _SwitchSettingLine extends StatelessWidget {
  const _SwitchSettingLine({
    required this.title,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _SettingLine(
    title: title,
    subtitle: subtitle,
    trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
  );
}

class _ShortcutKey extends StatelessWidget {
  const _ShortcutKey(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF303030)
            : const Color(0xFFF1F1F1),
        border: Border.all(color: DdColors.divider),
        borderRadius: BorderRadius.circular(DdRadii.pill),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}
