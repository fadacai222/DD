import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
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
  late final TextEditingController _displayName;
  late final TextEditingController _bio;
  AccountMe? _me;
  List<AccountDevice> _devices = const [];
  bool _busy = true;
  bool _allowEmailSearch = false;
  bool _allowStrangerMessages = false;
  bool _showOnlineStatus = true;
  bool _readReceipts = true;
  bool _notificationPreview = true;
  String? _message;
  int _section = 0;

  String get _accessToken => widget.session.tokens.accessToken;

  @override
  void initState() {
    super.initState();
    _displayName = TextEditingController();
    _bio = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _displayName.dispose();
    _bio.dispose();
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
        _sectionTitle('账号'),
        _profileEditor(),
        const SizedBox(height: 18),
        _sectionTitle('隐私与通用'),
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
    final me = _me;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('账号'),
        if (me != null)
          _SettingLine(
            title: me.profile.displayName,
            subtitle: '@${me.profile.handle} · ${me.profile.email}',
            trailing: OutlinedButton(
              onPressed: _busy ? null : _saveProfile,
              child: const Text('保存资料'),
            ),
          ),
        const Divider(height: 1),
        const SizedBox(height: 10),
        _profileEditor(),
        const SizedBox(height: 24),
        _sectionTitle('登录设备'),
        _deviceSettings(),
      ],
    );
  }

  Widget _generalSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('通用'),
        _privacySettings(),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _busy ? null : _saveProfile,
            child: const Text('保存设置'),
          ),
        ),
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DesktopSectionHeading('通知'),
        _SwitchSettingLine(
          title: '通知显示消息预览',
          subtitle: '关闭后系统通知不展示正文',
          value: _notificationPreview,
          enabled: !_busy,
          onChanged: (value) => setState(() => _notificationPreview = value),
        ),
        const Divider(height: 1),
        const _SettingLine(
          title: '会话免打扰',
          subtitle: '可在会话列表右键单独设置 8 小时或 7 天免打扰',
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _busy ? null : _saveProfile,
            child: const Text('保存通知设置'),
          ),
        ),
      ],
    );
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

  Widget _profileEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _displayName,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '昵称'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _bio,
          enabled: !_busy,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: '个人简介'),
        ),
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
          onChanged: (value) => setState(() => _allowEmailSearch = value),
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '允许陌生人消息',
          subtitle: '关闭后只有好友可以主动给你发送新消息',
          value: _allowStrangerMessages,
          enabled: !_busy,
          onChanged: (value) => setState(() => _allowStrangerMessages = value),
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '显示在线状态',
          value: _showOnlineStatus,
          enabled: !_busy,
          onChanged: (value) => setState(() => _showOnlineStatus = value),
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '已读回执',
          subtitle: '关闭后不会向对方暴露精确已读位置',
          value: _readReceipts,
          enabled: !_busy,
          onChanged: (value) => setState(() => _readReceipts = value),
        ),
        const Divider(height: 1),
        _SwitchSettingLine(
          title: '通知显示消息预览',
          value: _notificationPreview,
          enabled: !_busy,
          onChanged: (value) => setState(() => _notificationPreview = value),
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
        borderRadius: BorderRadius.circular(5),
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
      _displayName.text = me.profile.displayName;
      _bio.text = me.profile.bio;
      _allowEmailSearch = me.privacy.allowEmailSearch;
      _allowStrangerMessages = me.privacy.allowStrangerMessages;
      _showOnlineStatus = me.privacy.showOnlineStatus;
      _readReceipts = me.privacy.readReceiptsEnabled;
      _notificationPreview = me.privacy.notificationPreviewEnabled;
    });
  });

  Future<void> _saveProfile() => _run(() async {
    final me = await widget.gateway.updateMe(
      origin: widget.origin,
      accessToken: _accessToken,
      displayName: _displayName.text.trim(),
      bio: _bio.text.trim(),
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
      _message = '设置已保存。';
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
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}
