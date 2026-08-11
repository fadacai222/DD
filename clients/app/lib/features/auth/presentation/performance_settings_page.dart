import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/performance/app_performance_store.dart';
import '../../../theme/app_theme.dart';

class PerformanceSettingsPage extends StatelessWidget {
  const PerformanceSettingsPage({super.key, this.store});

  final AppPerformanceStore? store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '性能',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: PerformanceSettingsPanel(store: store),
    );
  }
}

class PerformanceSettingsPanel extends StatefulWidget {
  const PerformanceSettingsPanel({
    super.key,
    this.store,
    this.scrollable = true,
  });

  final AppPerformanceStore? store;
  final bool scrollable;

  @override
  State<PerformanceSettingsPanel> createState() =>
      _PerformanceSettingsPanelState();
}

class _PerformanceSettingsPanelState extends State<PerformanceSettingsPanel> {
  late final AppPerformanceStore _store;
  bool _saving = false;
  String? _error;

  bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? AppPerformanceStore.shared;
    _store.addListener(_handleChanged);
    unawaited(_store.load());
  }

  @override
  void dispose() {
    _store.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? const Color(0xFF292929) : const Color(0xFFF6F6F6);
    final children = <Widget>[
      const _PerformanceSectionTitle('性能模式'),
      _card(cardColor, <Widget>[
        _switchRow(
          key: const Key('performance-power-saving'),
          title: '节能模式',
          subtitle: '减少界面动画并暂停聊天中的视频自动预览，降低 CPU / GPU 占用。',
          value: _store.powerSaving,
          onChanged: (value) => _save(() => _store.setPowerSaving(value)),
        ),
      ]),
      const SizedBox(height: 20),
      const _PerformanceSectionTitle('图形与视频'),
      _card(cardColor, <Widget>[
        if (_windows) ...[
          const _PerformanceInfoRow(
            key: Key('performance-windows-gpu'),
            icon: Icons.speed_rounded,
            title: 'Windows 图形渲染',
            subtitle: 'DD Runner 已启用高性能 GPU 优先策略。',
            trailing: '高性能',
          ),
          const Divider(height: 1, indent: 52),
        ],
        _switchRow(
          key: const Key('performance-hardware-video'),
          title: '硬件加速视频解码',
          subtitle: '优先使用 GPU 解码视频；若显卡驱动出现花屏或崩溃，可关闭后重新打开视频。',
          value: _store.hardwareVideoDecoding,
          onChanged: (value) =>
              _save(() => _store.setHardwareVideoDecoding(value)),
        ),
        const Divider(height: 1, indent: 52),
        _switchRow(
          key: const Key('performance-video-autoplay'),
          title: '自动播放视频预览',
          subtitle: _store.powerSaving
              ? '节能模式开启时暂时停用。'
              : '聊天和朋友圈中，只自动播放当前最主要的可见视频。',
          value: _store.autoPlayVideoPreviews,
          onChanged: (value) =>
              _save(() => _store.setAutoPlayVideoPreviews(value)),
        ),
      ]),
      const SizedBox(height: 20),
      const _PerformanceSectionTitle('动画'),
      _card(cardColor, <Widget>[
        _switchRow(
          key: const Key('performance-reduce-motion'),
          title: '减少界面动画',
          subtitle: _store.powerSaving
              ? '节能模式已强制减少动画。'
              : '降低页面切换和装饰动画，适合远程桌面、低功耗或卡顿设备。',
          value: _store.reduceMotion,
          onChanged: (value) => _save(() => _store.setReduceMotion(value)),
        ),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(
          _error!,
          style: const TextStyle(fontSize: 12, color: DdColors.danger),
        ),
      ],
      const SizedBox(height: 16),
      Text(
        '说明：图形渲染继续由 Flutter GPU 管线负责；这里控制的是 DD 可安全动态调整的媒体解码、自动播放和动画策略。',
        style: TextStyle(
          fontSize: 11,
          height: 1.45,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ];
    if (widget.scrollable) {
      return ListView(
        key: const Key('performance-settings-panel'),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: children,
      );
    }
    return Padding(
      key: const Key('performance-settings-panel'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _card(Color color, List<Widget> children) => Material(
    color: color,
    borderRadius: BorderRadius.circular(DdRadii.surface),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );

  Widget _switchRow({
    required Key key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile.adaptive(
    key: key,
    secondary: Icon(
      title == '硬件加速视频解码'
          ? Icons.memory_rounded
          : title == '自动播放视频预览'
          ? Icons.play_circle_outline_rounded
          : title == '减少界面动画'
          ? Icons.motion_photos_off_outlined
          : Icons.battery_saver_outlined,
      size: 21,
      color: DdColors.textSecondary,
    ),
    title: Text(title, style: const TextStyle(fontSize: 14)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        subtitle,
        style: const TextStyle(
          fontSize: 11.5,
          height: 1.35,
          color: DdColors.textSecondary,
        ),
      ),
    ),
    value: value,
    onChanged: _saving ? null : onChanged,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
  );

  Future<void> _save(Future<void> Function() action) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '性能设置保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _PerformanceSectionTitle extends StatelessWidget {
  const _PerformanceSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: DdColors.textSecondary,
      ),
    ),
  );
}

class _PerformanceInfoRow extends StatelessWidget {
  const _PerformanceInfoRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 21, color: DdColors.textSecondary),
    title: Text(title, style: const TextStyle(fontSize: 14)),
    subtitle: Text(
      subtitle,
      style: const TextStyle(
        fontSize: 11.5,
        height: 1.35,
        color: DdColors.textSecondary,
      ),
    ),
    trailing: Text(
      trailing,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: DdColors.greenPressed,
      ),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
  );
}
