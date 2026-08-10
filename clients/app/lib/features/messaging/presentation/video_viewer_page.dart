import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/media/media_export_service.dart';
import '../../../core/media/remote_media_action_service.dart';

class VideoViewerPage extends StatefulWidget {
  const VideoViewerPage({
    super.key,
    required this.url,
    required this.fileName,
    required this.mimeType,
    this.remoteActions,
    this.remoteUrlResolver,
    this.retryUrlResolver,
    this.cacheInBackground,
  });

  final Uri url;
  final String fileName;
  final String mimeType;
  final RemoteMediaActionService? remoteActions;
  final Future<Uri> Function()? remoteUrlResolver;
  final Future<Uri> Function()? retryUrlResolver;
  final Future<void> Function(void Function(int received, int? total) onProgress)?
  cacheInBackground;

  @override
  State<VideoViewerPage> createState() => _VideoViewerPageState();
}

class _VideoViewerPageState extends State<VideoViewerPage> {
  late final Player _player;
  late final VideoController _controller;
  bool _saving = false;
  bool _copying = false;
  double _saveProgress = 0;
  double _cacheProgress = 0;
  bool _caching = false;
  String? _error;

  RemoteMediaActionService get _actions =>
      widget.remoteActions ?? RemoteMediaActionService();

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    unawaited(_open());
    unawaited(_warmCache());
  }

  Future<void> _open([Uri? overrideUrl]) async {
    if (mounted) setState(() => _error = null);
    try {
      await _player.open(Media((overrideUrl ?? widget.url).toString()), play: true);
    } catch (_) {
      if (mounted) setState(() => _error = '视频加载失败，请检查网络或视频编码。');
    }
  }

  Future<void> _retryOpen() async {
    try {
      final resolver = widget.retryUrlResolver;
      await _open(resolver == null ? null : await resolver());
    } catch (_) {
      if (mounted) setState(() => _error = '视频加载失败，请稍后重试。');
    }
  }

  Future<void> _warmCache() async {
    final cache = widget.cacheInBackground;
    if (cache == null || _caching) return;
    if (mounted) {
      setState(() {
        _caching = true;
        _cacheProgress = 0;
      });
    }
    try {
      await cache((received, total) {
        if (!mounted || total == null || total <= 0) return;
        final progress = (received / total).clamp(0.0, 1.0);
        if ((progress - _cacheProgress).abs() >= 0.02 || progress == 1) {
          setState(() => _cacheProgress = progress);
        }
      });
    } catch (_) {
      // Persistent caching is an optimization. Streaming playback remains
      // authoritative and a later open can retry with a fresh download grant.
    } finally {
      if (mounted) setState(() => _caching = false);
    }
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_error == null)
              Video(
                controller: _controller,
                fit: BoxFit.contain,
                fill: Colors.black,
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('video-viewer-retry'),
                      onPressed: _retryOpen,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Positioned(
              left: 10,
              top: 8,
              child: _roundButton(
                tooltip: '关闭',
                onPressed: () => Navigator.maybePop(context),
                icon: Icons.close_rounded,
              ),
            ),
            Positioned(
              right: 10,
              top: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (kIsWeb ||
                      defaultTargetPlatform != TargetPlatform.android) ...[
                    _roundButton(
                      key: const Key('video-viewer-copy'),
                      tooltip: '复制视频',
                      onPressed: _copying ? null : _copy,
                      icon: Icons.content_copy_rounded,
                      progress: _copying,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _roundButton(
                    key: const Key('video-viewer-save'),
                    tooltip: '保存视频',
                    onPressed: _saving ? null : _save,
                    icon: Icons.download_rounded,
                    progress: _saving,
                  ),
                ],
              ),
            ),
            if (_saving && _saveProgress > 0 && _saveProgress < 1)
              Positioned(
                left: 24,
                right: 24,
                bottom: 22,
                child: LinearProgressIndicator(
                  value: _saveProgress,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  color: Colors.white,
                ),
              )
            else if (_caching && _cacheProgress > 0 && _cacheProgress < 1)
              Positioned(
                left: 24,
                right: 24,
                bottom: 22,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '正在缓存 ${(100 * _cacheProgress).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 5),
                    LinearProgressIndicator(
                      value: _cacheProgress,
                      minHeight: 3,
                      backgroundColor: Colors.white24,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    Key? key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
    bool progress = false,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: Colors.black.withValues(alpha: 0.52),
      foregroundColor: Colors.white,
    ),
    icon: progress
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Icon(icon),
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveProgress = 0;
    });
    try {
      final message = await _actions.saveVideo(
        url: await _resolveRemoteUrl(),
        mimeType: widget.mimeType,
        suggestedName: widget.fileName,
        onProgress: (received, total) {
          if (!mounted || total == null || total <= 0) return;
          final next = (received / total).clamp(0.0, 1.0);
          if ((next - _saveProgress).abs() >= 0.01 || next == 1) {
            setState(() => _saveProgress = next);
          }
        },
      );
      if (mounted) _show(message);
    } on MediaExportCancelled {
      // User cancelled the save dialog.
    } catch (_) {
      if (mounted) _show('视频保存失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveProgress = 0;
        });
      }
    }
  }

  Future<void> _copy() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      final message = await _actions.copyVideo(
        url: await _resolveRemoteUrl(),
        mimeType: widget.mimeType,
        suggestedName: widget.fileName,
      );
      if (mounted) _show(message);
    } catch (_) {
      if (mounted) _show('视频复制失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<Uri> _resolveRemoteUrl() async {
    final resolver = widget.remoteUrlResolver;
    return resolver == null ? widget.url : resolver();
  }

  void _show(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
