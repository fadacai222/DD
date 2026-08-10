import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/media/media_cache_manager.dart';
import '../../../theme/app_theme.dart';
import '../data/media_auto_download_store.dart';

class MediaStorageSettingsPage extends StatefulWidget {
  const MediaStorageSettingsPage({
    super.key,
    required this.userId,
    this.preferencesStore,
    this.cacheManager,
  });

  final String userId;
  final MediaAutoDownloadStore? preferencesStore;
  final MediaCacheGateway? cacheManager;

  @override
  State<MediaStorageSettingsPage> createState() =>
      _MediaStorageSettingsPageState();
}

class _MediaStorageSettingsPageState
    extends State<MediaStorageSettingsPage> {
  late final MediaAutoDownloadStore _store;
  late final MediaCacheGateway _cache;
  MediaAutoDownloadPreferences _preferences =
      const MediaAutoDownloadPreferences();
  MediaCacheSummary _summary = const MediaCacheSummary(<MediaCacheKind, int>{});
  bool _loading = true;
  bool _saving = false;
  bool _clearing = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _store = widget.preferencesStore ??
        MediaAutoDownloadStore.shared(widget.userId);
    _cache = widget.cacheManager ?? const MediaCacheManager();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        _store.load(),
        _cache.snapshot(),
      ]);
      if (!mounted) return;
      setState(() {
        _preferences = results[0] as MediaAutoDownloadPreferences;
        _summary = results[1] as MediaCacheSummary;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = '媒体设置加载失败。';
      });
    }
  }

  Future<void> _update(
    MediaAutoDownloadPreferences Function(MediaAutoDownloadPreferences current)
        update,
  ) async {
    if (_saving) return;
    final previous = _preferences;
    final next = update(previous);
    setState(() {
      _preferences = next;
      _saving = true;
      _message = null;
    });
    try {
      await _store.save(next);
    } catch (_) {
      if (mounted) {
        setState(() {
          _preferences = previous;
          _message = '自动下载设置保存失败。';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearKind(MediaCacheKind kind) async {
    if (_clearing) return;
    setState(() {
      _clearing = true;
      _message = null;
    });
    try {
      await _cache.clear(kind);
      final summary = await _cache.snapshot();
      if (mounted) {
        setState(() {
          _summary = summary;
          _message = '${_labelForKind(kind)}缓存已清理';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '缓存清理失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearAll() async {
    if (_clearing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理全部缓存？'),
        content: const Text('只会删除 DD 的本地缓存，不会删除聊天记录、收藏、服务端媒体或已保存到系统目录的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _clearing = true;
      _message = null;
    });
    try {
      await _cache.clearAll();
      final summary = await _cache.snapshot();
      if (mounted) {
        setState(() {
          _summary = summary;
          _message = '缓存已清理';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '缓存清理失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体与缓存'),
        actions: [
          TextButton(
            key: const Key('media-cache-clear-all'),
            onPressed: _loading || _clearing ? null : _clearAll,
            child: const Text('清理全部'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                if (_message != null) ...[
                  Text(
                    _message!,
                    style: const TextStyle(color: DdColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                ],
                const _SectionTitle('自动下载'),
                const Text(
                  '这里只控制下载到 DD 本地缓存，不会自动保存到系统相册或下载目录。当前版本不伪装区分 Wi‑Fi / 移动网络。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: DdColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                _switch(
                  key: const Key('media-auto-images'),
                  title: '图片',
                  value: _preferences.images,
                  onChanged: (value) => _update(
                    (current) => current.copyWith(images: value),
                  ),
                ),
                _switch(
                  key: const Key('media-auto-gif-stickers'),
                  title: 'GIF / Sticker',
                  value: _preferences.gifAndStickers,
                  onChanged: (value) => _update(
                    (current) => current.copyWith(gifAndStickers: value),
                  ),
                ),
                _switch(
                  key: const Key('media-auto-videos'),
                  title: '视频',
                  subtitle: '开启后在看到缩略图时后台缓存完整视频',
                  value: _preferences.videos,
                  onChanged: (value) => _update(
                    (current) => current.copyWith(videos: value),
                  ),
                ),
                _switch(
                  key: const Key('media-auto-files'),
                  title: '文件',
                  subtitle: '开启后在会话中看到文件消息时后台缓存',
                  value: _preferences.files,
                  onChanged: (value) => _update(
                    (current) => current.copyWith(files: value),
                  ),
                ),
                const SizedBox(height: 22),
                const _SectionTitle('本地缓存'),
                _cacheRow(MediaCacheKind.image),
                _cacheRow(MediaCacheKind.video),
                _cacheRow(MediaCacheKind.file),
                _cacheRow(MediaCacheKind.voice),
                _cacheRow(MediaCacheKind.stickerGif),
                _cacheRow(MediaCacheKind.temporary),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('合计'),
                  trailing: Text(
                    formatMediaCacheBytes(_summary.totalBytes),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: DdColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '正在下载、播放或写入的缓存会被保护并跳过清理；稍后可再次清理。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: DdColors.textSecondary,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _switch({
    required Key key,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile.adaptive(
    key: key,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: 12)),
    value: value,
    onChanged: _saving ? null : onChanged,
  );

  Widget _cacheRow(MediaCacheKind kind) => ListTile(
    key: Key('media-cache-${kind.name}'),
    contentPadding: EdgeInsets.zero,
    title: Text(_labelForKind(kind)),
    subtitle: Text(formatMediaCacheBytes(_summary.bytesFor(kind))),
    trailing: TextButton(
      onPressed: _clearing || _summary.bytesFor(kind) == 0
          ? null
          : () => _clearKind(kind),
      child: const Text('清理'),
    ),
  );

  String _labelForKind(MediaCacheKind kind) => switch (kind) {
    MediaCacheKind.image => '图片',
    MediaCacheKind.video => '视频',
    MediaCacheKind.file => '文件',
    MediaCacheKind.voice => '语音',
    MediaCacheKind.stickerGif => 'Sticker / GIF',
    MediaCacheKind.temporary => '临时文件',
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );
}
