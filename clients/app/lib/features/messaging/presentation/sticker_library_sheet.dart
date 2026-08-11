import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/logging/client_log.dart';
import '../../../theme/app_theme.dart';
import '../data/sticker_api_client.dart';
import '../domain/emoji_catalog.dart';
import '../domain/sticker_models.dart';
import '../domain/telegram_sticker_link.dart';

class StickerLibrarySheet extends StatefulWidget {
  const StickerLibrarySheet({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.emoji,
    required this.recentEmoji,
    this.emojiCategories,
    required this.mediaBytesLoader,
    required this.onAddCustomSticker,
    this.initialTabKey = 'emoji',
    this.onTabChanged,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final List<String> emoji;
  final List<String> recentEmoji;
  final List<EmojiCategoryData>? emojiCategories;
  final Future<Uint8List> Function(String mediaId) mediaBytesLoader;
  final Future<CustomStickerItem?> Function(StickerGateway gateway)
  onAddCustomSticker;
  final String initialTabKey;
  final ValueChanged<String>? onTabChanged;
  final StickerGateway? gateway;

  @override
  State<StickerLibrarySheet> createState() => _StickerLibrarySheetState();
}

class _StickerLibrarySheetState extends State<StickerLibrarySheet> {
  late final StickerGateway _gateway;
  late final bool _ownsGateway;
  List<CustomStickerItem> _custom = const [];
  List<StickerPackItemGroup> _packs = const [];
  int _selectedTab = 0;
  int _selectedEmojiCategory = 0;
  bool _restoredInitialTab = false;
  bool _loading = true;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? StickerApiClient();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        _gateway.listCustomStickers(
          origin: widget.origin,
          accessToken: widget.accessToken,
        ),
        _gateway.listStickerPacks(
          origin: widget.origin,
          accessToken: widget.accessToken,
        ),
      ]);
      if (!mounted) return;
      final custom = results[0] as List<CustomStickerItem>;
      final packs = results[1] as List<StickerPackItemGroup>;
      setState(() {
        _custom = custom;
        _packs = packs;
        if (!_restoredInitialTab) {
          _selectedTab = _tabIndexForKey(widget.initialTabKey, packs);
          _restoredInitialTab = true;
        } else {
          _selectedTab = _selectedTab.clamp(0, _packs.length + 1);
        }
        _loading = false;
      });
    } catch (error, stackTrace) {
      unawaited(
        ClientLog.error(
          'sticker-library load failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final targetHeight = (MediaQuery.sizeOf(context).height * 0.58).clamp(
      320.0,
      520.0,
    );
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: SizedBox(
          key: const Key('sticker-library-sheet'),
          height: targetHeight,
          child: Column(
            children: [
              _toolbar(),
              const Divider(height: 1),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              key: const Key('sticker-tabs'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              children: [
                _tab(
                  key: const Key('sticker-tab-emoji'),
                  index: 0,
                  tooltip: 'Emoji',
                  child: const Icon(Icons.emoji_emotions_outlined, size: 23),
                ),
                _tab(
                  key: const Key('sticker-tab-custom'),
                  index: 1,
                  tooltip: '自定义表情',
                  child: const Icon(Icons.favorite_outline_rounded, size: 23),
                ),
                for (var index = 0; index < _packs.length; index++)
                  _tab(
                    key: Key('sticker-tab-pack-${_packs[index].id}'),
                    index: index + 2,
                    tooltip: _packs[index].title,
                    child: _packTabIcon(_packs[index]),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('sticker-import-pack'),
            tooltip: '添加 Telegram 贴纸包',
            onPressed: _busy ? null : _importTelegramPack,
            icon: const Icon(Icons.add_link_rounded),
          ),
          if (_selectedTab == 1)
            IconButton(
              key: const Key('sticker-manage-custom'),
              tooltip: '管理自定义表情',
              onPressed: _busy ? null : _openCustomManager,
              icon: const Icon(Icons.tune_rounded),
            ),
          if (_selectedTab >= 2 && _selectedTab - 2 < _packs.length)
            IconButton(
              key: const Key('sticker-remove-pack'),
              tooltip: '移除贴纸包',
              onPressed: _busy ? null : _confirmRemovePack,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
    );
  }

  Widget _tab({
    required Key key,
    required int index,
    required String tooltip,
    required Widget child,
  }) {
    final selected = index == _selectedTab;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(DdRadii.pill),
          onTap: () => _selectTab(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? DdColors.green.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DdRadii.pill),
            ),
            child: IconTheme(
              data: IconThemeData(
                color: selected
                    ? DdColors.greenPressed
                    : DdColors.textSecondary,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  int _tabIndexForKey(String rawKey, List<StickerPackItemGroup> packs) {
    final key = rawKey.trim();
    if (key == 'custom') return 1;
    if (key.startsWith('pack:')) {
      final packId = key.substring('pack:'.length);
      final index = packs.indexWhere((pack) => pack.id == packId);
      return index < 0 ? 1 : index + 2;
    }
    return 0;
  }

  String _tabKeyForIndex(int index) {
    if (index == 1) return 'custom';
    final packIndex = index - 2;
    if (packIndex >= 0 && packIndex < _packs.length) {
      return 'pack:${_packs[packIndex].id}';
    }
    return 'emoji';
  }

  void _selectTab(int index) {
    if (index == _selectedTab) return;
    setState(() => _selectedTab = index);
    widget.onTabChanged?.call(_tabKeyForIndex(index));
  }

  Widget _packTabIcon(StickerPackItemGroup pack) {
    final mediaId = pack.coverMediaId.isNotEmpty
        ? pack.coverMediaId
        : pack.items.firstOrNull?.mediaId ?? '';
    if (mediaId.isEmpty) {
      return const Icon(Icons.auto_awesome_rounded, size: 22);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: _StickerThumb(
        mediaId: mediaId,
        mimeType: 'image/webp',
        loader: widget.mediaBytesLoader,
        size: 31,
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.sentiment_dissatisfied_outlined,
                size: 30,
                color: DdColors.textSecondary,
              ),
              const SizedBox(height: 8),
              Text(
                _libraryLoadErrorText(_error!),
                key: const Key('sticker-library-load-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_selectedTab == 0) return _emojiGrid();
    if (_selectedTab == 1) return _customGrid();
    final packIndex = _selectedTab - 2;
    if (packIndex < 0 || packIndex >= _packs.length) return _emojiGrid();
    return _packGrid(_packs[packIndex]);
  }

  Widget _emojiGrid() {
    final categories = widget.emojiCategories ?? EmojiCatalog.categories;
    final category = categories.isEmpty
        ? null
        : categories[_selectedEmojiCategory.clamp(0, categories.length - 1)];
    final items = category?.items ?? widget.emoji;
    return CustomScrollView(
      key: const Key('sticker-emoji-grid'),
      slivers: [
        if (categories.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView.builder(
                key: const Key('emoji-category-tabs'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                itemCount: categories.length,
                itemBuilder: (context, index) {
                  final item = categories[index];
                  final selected = index == _selectedEmojiCategory;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Tooltip(
                      message: item.label,
                      child: InkWell(
                        key: Key('emoji-category-${item.key.name}'),
                        borderRadius: BorderRadius.circular(DdRadii.pill),
                        onTap: () => setState(() => _selectedEmojiCategory = index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected
                                ? DdColors.green.withValues(alpha: 0.13)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(DdRadii.pill),
                          ),
                          child: Text(
                            item.icon,
                            style: TextStyle(
                              fontSize: 22,
                              color: selected ? DdColors.greenPressed : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        if (widget.recentEmoji.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Text(
                '最近使用',
                style: TextStyle(fontSize: 11, color: DdColors.textSecondary),
              ),
            ),
          ),
          SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 52,
              mainAxisExtent: 48,
            ),
            itemCount: widget.recentEmoji.length,
            itemBuilder: (_, index) => _emojiCell(widget.recentEmoji[index]),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
        ],
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 52,
              mainAxisExtent: 48,
            ),
            itemCount: items.length,
            itemBuilder: (_, index) => _emojiCell(items[index]),
          ),
        ),
      ],
    );
  }

  Widget _emojiCell(String emoji) => InkWell(
    borderRadius: BorderRadius.circular(DdRadii.control),
    onTap: () => Navigator.pop(context, EmojiPanelResult(emoji)),
    child: Center(child: Text(emoji, style: const TextStyle(fontSize: 25))),
  );

  Widget _customGrid() {
    return GridView.builder(
      key: const Key('sticker-custom-grid'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 92,
        mainAxisExtent: 88,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _custom.length + 1,
      itemBuilder: (_, index) {
        if (index == 0) {
          return InkWell(
            key: const Key('sticker-custom-add'),
            borderRadius: BorderRadius.circular(DdRadii.control),
            onTap: _busy ? null : _addCustomSticker,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: DdColors.divider),
                borderRadius: BorderRadius.circular(DdRadii.control),
              ),
              child: const Center(
                child: Icon(
                  Icons.add_rounded,
                  size: 30,
                  color: DdColors.textSecondary,
                ),
              ),
            ),
          );
        }
        final sticker = _custom[index - 1];
        return _stickerCell(
          sticker.asset,
          key: Key('custom-sticker-${sticker.id}'),
        );
      },
    );
  }

  Widget _packGrid(StickerPackItemGroup pack) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 7),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  pack.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (pack.unsupportedStickerCount > 0)
                Text(
                  '${pack.unsupportedStickerCount} 个动态/视频表情暂不支持',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: DdColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            key: Key('sticker-pack-grid-${pack.id}'),
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 92,
              mainAxisExtent: 88,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: pack.items.length,
            itemBuilder: (_, index) {
              final item = pack.items[index];
              return _stickerCell(
                item.asset,
                key: Key('pack-sticker-${item.id}'),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _stickerCell(StickerAsset asset, {required Key key}) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(DdRadii.control),
      onTap: () => Navigator.pop(context, StickerAssetPanelResult(asset)),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: _StickerThumb(
          mediaId: asset.mediaId,
          mimeType: asset.mimeType,
          loader: widget.mediaBytesLoader,
          size: 74,
        ),
      ),
    );
  }

  Future<void> _addCustomSticker() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final created = await widget.onAddCustomSticker(_gateway);
      if (!mounted || created == null) return;
      setState(() => _custom = [..._custom, created]);
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCustomManager() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CustomStickerManagerPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          gateway: _gateway,
          initialItems: _custom,
          mediaBytesLoader: widget.mediaBytesLoader,
          onAddCustomSticker: widget.onAddCustomSticker,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _importTelegramPack() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _TelegramStickerImportDialog(),
    );
    if (raw == null || !mounted) return;
    late String setName;
    try {
      setName = parseTelegramStickerSetName(raw);
    } on FormatException catch (error) {
      _showError(error.message);
      return;
    }
    setState(() => _busy = true);
    try {
      final pack = await _gateway.importTelegramPack(
        origin: widget.origin,
        accessToken: widget.accessToken,
        setName: setName,
      );
      if (!mounted) return;
      final next = <StickerPackItemGroup>[
        for (final item in _packs)
          if (item.id != pack.id) item,
        pack,
      ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final selectedIndex = next.indexWhere((item) => item.id == pack.id) + 2;
      setState(() {
        _packs = next;
        _selectedTab = selectedIndex;
      });
      widget.onTabChanged?.call('pack:${pack.id}');
      if (pack.unsupportedStickerCount > 0) {
        _showError(
          '已添加 ${pack.supportedStickerCount} 个静态贴纸；${pack.unsupportedStickerCount} 个动态/视频贴纸当前暂不支持。',
        );
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemovePack() async {
    final packIndex = _selectedTab - 2;
    if (packIndex < 0 || packIndex >= _packs.length) return;
    final pack = _packs[packIndex];
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('移除贴纸包？'),
            content: Text('“${pack.title}”会从你的表情面板移除，已发送的贴纸不会受影响。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('移除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _gateway.removeStickerPack(
        origin: widget.origin,
        accessToken: widget.accessToken,
        packId: pack.id,
      );
      if (!mounted) return;
      setState(() {
        _packs = _packs
            .where((item) => item.id != pack.id)
            .toList(growable: false);
        _selectedTab = 1;
      });
      widget.onTabChanged?.call('custom');
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _libraryLoadErrorText(Object error) {
    if (error is StickerApiException) {
      if (error.code == 'STICKERS_UNAVAILABLE') {
        return '当前 DD 服务端没有启用表情服务。请重新构建并重启服务端，再确认数据库迁移已执行到 000016。';
      }
      if (error.statusCode == 404) {
        return '当前客户端已包含新版表情系统，但正在连接的服务端还没有对应接口。请重新构建并重启 DD 服务端。';
      }
      return '${error.message}\n${error.code} · HTTP ${error.statusCode}';
    }
    if (error is FormatException) {
      return '表情服务返回了无法识别的数据。请确认客户端与服务端版本一致后重试。';
    }
    return '表情库暂时加载失败。请检查网络与服务端日志后重试。';
  }

  String _operationErrorText(Object error) {
    if (error is StickerApiException) {
      return switch (error.code) {
        'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED' =>
          '当前 DD 服务端未配置 Telegram Bot Token。请在 infra/dev/.env 设置 TELEGRAM_BOT_TOKEN 后重启服务端。',
        'TELEGRAM_STICKER_RELAY_UNAVAILABLE' => 'Telegram 贴纸中继暂时不可用，请稍后重试。',
        'TELEGRAM_STICKER_FORMAT_UNSUPPORTED' => '这个贴纸包目前没有可导入的静态 WebP 贴纸。',
        'TELEGRAM_STICKER_TOO_LARGE' => '贴纸包中有文件超过当前实例允许的大小。',
        _ => error.message,
      };
    }
    if (error is String) return error;
    return error.toString();
  }

  void _showError(Object error) {
    final message = _operationErrorText(error);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _TelegramStickerImportDialog extends StatefulWidget {
  const _TelegramStickerImportDialog();

  @override
  State<_TelegramStickerImportDialog> createState() =>
      _TelegramStickerImportDialogState();
}

class _TelegramStickerImportDialogState
    extends State<_TelegramStickerImportDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 Telegram 贴纸包'),
      content: TextField(
        key: const Key('telegram-sticker-link-input'),
        controller: _controller,
        maxLines: 2,
        decoration: const InputDecoration(
          hintText: '粘贴 https://t.me/addstickers/...',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('telegram-sticker-import-confirm'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class CustomStickerManagerPage extends StatefulWidget {
  const CustomStickerManagerPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.gateway,
    required this.initialItems,
    required this.mediaBytesLoader,
    required this.onAddCustomSticker,
  });

  final Uri origin;
  final String accessToken;
  final StickerGateway gateway;
  final List<CustomStickerItem> initialItems;
  final Future<Uint8List> Function(String mediaId) mediaBytesLoader;
  final Future<CustomStickerItem?> Function(StickerGateway gateway)
  onAddCustomSticker;

  @override
  State<CustomStickerManagerPage> createState() =>
      _CustomStickerManagerPageState();
}

class _CustomStickerManagerPageState extends State<CustomStickerManagerPage> {
  late List<CustomStickerItem> _items;
  final Set<String> _selected = {};
  bool _organizing = false;
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _items = List<CustomStickerItem>.from(widget.initialItems);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 74,
        leading: TextButton(
          key: const Key('custom-sticker-close'),
          onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          child: const Text('关闭'),
        ),
        title: const Text('自定义表情'),
        actions: [
          TextButton(
            key: const Key('custom-sticker-organize'),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _organizing = !_organizing;
                    if (!_organizing) _selected.clear();
                  }),
            child: Text(_organizing ? '完成' : '整理'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: GridView.builder(
        key: const Key('custom-sticker-manager-grid'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 108,
          mainAxisExtent: 100,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: _items.length + (_organizing ? 0 : 1),
        itemBuilder: (_, index) {
          if (!_organizing && index == 0) return _addCell();
          final item = _items[index - (_organizing ? 0 : 1)];
          return _managerStickerCell(item);
        },
      ),
      bottomNavigationBar: _organizing
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: FilledButton.icon(
                  key: const Key('custom-sticker-delete-selected'),
                  style: FilledButton.styleFrom(
                    backgroundColor: DdColors.danger,
                  ),
                  onPressed: _busy || _selected.isEmpty
                      ? null
                      : _deleteSelected,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(
                    '删除${_selected.isEmpty ? '' : ' (${_selected.length})'}',
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget _addCell() => InkWell(
    key: const Key('custom-sticker-manager-add'),
    borderRadius: BorderRadius.circular(DdRadii.control),
    onTap: _busy ? null : _add,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: DdColors.divider),
        borderRadius: BorderRadius.circular(DdRadii.control),
      ),
      child: const Center(child: Icon(Icons.add_rounded, size: 32)),
    ),
  );

  Widget _managerStickerCell(CustomStickerItem item) {
    final selected = _selected.contains(item.id);
    return InkWell(
      key: Key('custom-sticker-manager-${item.id}'),
      borderRadius: BorderRadius.circular(DdRadii.control),
      onTap: _organizing
          ? () => setState(() {
              if (!selected) {
                _selected.add(item.id);
              } else {
                _selected.remove(item.id);
              }
            })
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: _StickerThumb(
              mediaId: item.mediaId,
              mimeType: item.mimeType,
              loader: widget.mediaBytesLoader,
              size: 84,
            ),
          ),
          if (_organizing)
            Positioned(
              right: 5,
              top: 5,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? DdColors.green : Colors.black38,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      final item = await widget.onAddCustomSticker(widget.gateway);
      if (!mounted || item == null) return;
      setState(() {
        _items.add(item);
        _changed = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除选中的表情？'),
            content: Text(
              '将从你的自定义表情库删除 ${_selected.length} 个表情；已发送的聊天消息不会受影响。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: DdColors.danger),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final ids = _selected.toList(growable: false);
    setState(() => _busy = true);
    try {
      await widget.gateway.deleteCustomStickers(
        origin: widget.origin,
        accessToken: widget.accessToken,
        stickerIds: ids,
      );
      if (!mounted) return;
      setState(() {
        _items.removeWhere((item) => _selected.contains(item.id));
        _selected.clear();
        _changed = true;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StickerApiException ? error.message : error.toString(),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _StickerThumb extends StatelessWidget {
  const _StickerThumb({
    required this.mediaId,
    required this.mimeType,
    required this.loader,
    required this.size,
  });

  final String mediaId;
  final String mimeType;
  final Future<Uint8List> Function(String mediaId) loader;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (mimeType == 'image/gif') {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(DdRadii.control),
          ),
          child: const Center(
            child: Text('GIF', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      );
    }
    return FutureBuilder<Uint8List>(
      future: loader(mediaId),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          if (snapshot.hasError) {
            return SizedBox.square(
              dimension: size,
              child: const Icon(
                Icons.broken_image_outlined,
                color: DdColors.textTertiary,
              ),
            );
          }
          return SizedBox.square(
            dimension: size,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.7),
              ),
            ),
          );
        }
        return Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        );
      },
    );
  }
}
