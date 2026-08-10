import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../data/chat_appearance_store.dart';
import 'chat_wallpaper_surface.dart';

class ChatBackgroundSettingsPage extends StatefulWidget {
  const ChatBackgroundSettingsPage({
    super.key,
    required this.store,
    this.conversationId,
  });

  final ChatAppearanceStore store;
  final String? conversationId;

  bool get conversationMode =>
      conversationId != null && conversationId!.trim().isNotEmpty;

  @override
  State<ChatBackgroundSettingsPage> createState() =>
      _ChatBackgroundSettingsPageState();
}

class _ChatBackgroundSettingsPageState
    extends State<ChatBackgroundSettingsPage> {
  static const _palette = <int>[
    0xFFECEFEB,
    0xFFF4EFE7,
    0xFFE8F0F4,
    0xFFE7F2EC,
    0xFFF3E9EC,
    0xFFECE9F4,
  ];

  bool _busy = true;
  String? _error;

  String get _previewConversationId =>
      widget.conversationId ?? '__global_wallpaper_preview__';

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_storeChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    super.dispose();
  }

  void _storeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await widget.store.load();
    } catch (_) {
      if (mounted) _error = '聊天背景设置加载失败。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationMode = widget.conversationMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(conversationMode ? '当前聊天背景' : '聊天背景'),
        centerTitle: true,
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
              children: [
                if (_error != null) ...[
                  _errorBanner(),
                  const SizedBox(height: 12),
                ],
                AspectRatio(
                  aspectRatio: 16 / 10,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(DdRadii.surface),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ChatWallpaperSurface(
                          store: widget.store,
                          conversationId: _previewConversationId,
                          wallpaperOverride: conversationMode
                              ? null
                              : widget.store.state.globalWallpaper,
                        ),
                        const Positioned(
                          left: 18,
                          right: 18,
                          bottom: 18,
                          child: _WallpaperMessagePreview(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (conversationMode) ...[
                  _sectionTitle('当前聊天'),
                  _settingsRow(
                    key: const Key('chat-background-follow-global'),
                    icon: Icons.layers_outlined,
                    title: '跟随全局背景',
                    subtitle: '以后修改全局背景时，这个聊天自动跟随',
                    onTap: _busy ? null : _followGlobal,
                  ),
                  const SizedBox(height: 12),
                ],
                _sectionTitle('背景类型'),
                _settingsRow(
                  key: const Key('chat-background-system'),
                  icon: Icons.auto_awesome_outlined,
                  title: 'DD 默认背景',
                  subtitle: '原创低对比图案，不使用第三方专有壁纸',
                  onTap: _busy ? null : _setSystem,
                ),
                _settingsRow(
                  key: const Key('chat-background-custom'),
                  icon: Icons.photo_library_outlined,
                  title: '从图片选择',
                  subtitle: '会压缩并复制到 DD 自己的存储目录',
                  onTap: _busy ? null : _pickCustom,
                ),
                const SizedBox(height: 18),
                _sectionTitle('纯色'),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final color in _palette)
                      InkWell(
                        key: Key('chat-background-color-$color'),
                        borderRadius: BorderRadius.circular(DdRadii.pill),
                        onTap: _busy ? null : () => _setSolid(color),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Color(color),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white24
                                  : Colors.black12,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );

  Widget _settingsRow({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(DdRadii.surface),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: key,
        leading: Icon(icon, color: DdColors.greenPressed),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: DdColors.textTertiary,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _errorBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: const Color(0xFFFFE8E8),
      borderRadius: BorderRadius.circular(DdRadii.control),
    ),
    child: Text(
      _error!,
      style: const TextStyle(fontSize: 12, color: Color(0xFF9D2323)),
    ),
  );

  Future<void> _setSystem() => _run(() async {
    if (widget.conversationMode) {
      await widget.store.setConversationSystem(widget.conversationId!);
    } else {
      await widget.store.setGlobalSystem();
    }
  });

  Future<void> _setSolid(int color) => _run(() async {
    if (widget.conversationMode) {
      await widget.store.setConversationSolid(widget.conversationId!, color);
    } else {
      await widget.store.setGlobalSolid(color);
    }
  });

  Future<void> _followGlobal() => _run(() async {
    await widget.store.followGlobal(widget.conversationId!);
  });

  Future<void> _pickCustom() async {
    const group = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null || !mounted) return;
    await _run(() async {
      final source = await file.readAsBytes();
      if (widget.conversationMode) {
        await widget.store.setConversationCustom(
          widget.conversationId!,
          source,
        );
      } else {
        await widget.store.setGlobalCustom(source);
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '聊天背景更新失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _WallpaperMessagePreview extends StatelessWidget {
  const _WallpaperMessagePreview();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(DdRadii.messageBubble),
            ),
            child: const Text(
              '这是背景预览',
              style: TextStyle(color: Colors.black87),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: DdColors.ownBubble.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(DdRadii.messageBubble),
            ),
            child: const Text(
              '消息必须依然清晰',
              style: TextStyle(color: Colors.black87),
            ),
          ),
        ),
      ],
    );
  }
}
