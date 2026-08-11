import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/media/media_cache_lease_registry.dart';
import '../../../core/media/media_export_service.dart';
import '../../../core/media/remote_media_action_service.dart';
import '../../../core/window/picture_in_picture_service.dart';

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
    this.onPictureInPicture,
    this.initialPosition = Duration.zero,
    this.autoPlay = true,
  });

  final Uri url;
  final String fileName;
  final String mimeType;
  final RemoteMediaActionService? remoteActions;
  final Future<Uri> Function()? remoteUrlResolver;
  final Future<Uri> Function()? retryUrlResolver;
  final Future<void> Function(void Function(int received, int? total) onProgress)?
  cacheInBackground;
  final Future<void> Function(Duration position, bool playing)? onPictureInPicture;
  final Duration initialPosition;
  final bool autoPlay;

  @override
  State<VideoViewerPage> createState() => _VideoViewerPageState();
}

class _VideoViewerPageState extends State<VideoViewerPage> {
  late final Player _player;
  late final VideoController _controller;
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'video-viewer');
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<double>? _volumeSubscription;
  StreamSubscription<double>? _rateSubscription;
  StreamSubscription<String>? _errorSubscription;
  MediaCacheLease? _playbackLease;
  final Stopwatch _startupWatch = Stopwatch();
  bool _firstFrameLogged = false;
  Timer? _controlsTimer;

  bool _saving = false;
  bool _sharing = false;
  bool _playing = false;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _muted = false;
  bool _systemPipSupported = false;
  double _volume = 100;
  double _rate = 1;
  double _saveProgress = 0;
  double _cacheProgress = 0;
  bool _caching = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  RemoteMediaActionService get _actions =>
      widget.remoteActions ?? RemoteMediaActionService();

  bool get _desktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _startupWatch.start();
    if (widget.url.scheme == 'file') {
      _playbackLease = MediaCacheLeaseRegistry.shared.acquire(
        widget.url.toFilePath(),
      );
    }
    _playingSubscription = _player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
      if (value) _scheduleControlsHide();
    });
    _positionSubscription = _player.stream.position.listen((value) {
      if (!_firstFrameLogged && value > Duration.zero) {
        _firstFrameLogged = true;
        _startupWatch.stop();
        unawaited(
          ClientLog.info(
            'Video first frame: ${_startupWatch.elapsedMilliseconds}ms, '
            '${_player.state.width ?? 0}x${_player.state.height ?? 0}, '
            'hardwareAcceleration=true, platform=$defaultTargetPlatform',
          ),
        );
      }
      if (mounted) setState(() => _position = value);
    });
    _durationSubscription = _player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _volumeSubscription = _player.stream.volume.listen((value) {
      if (mounted) {
        setState(() {
          _volume = value;
          _muted = value <= 0.01;
        });
      }
    });
    _rateSubscription = _player.stream.rate.listen((value) {
      if (mounted) setState(() => _rate = value);
    });
    _errorSubscription = _player.stream.error.listen((message) {
      if (!mounted || message.trim().isEmpty) return;
      setState(() => _error = '视频解码或图形设备异常，可重试。');
      unawaited(ClientLog.error('Video runtime error: $message'));
    });
    unawaited(_open());
    unawaited(_warmCache());
    unawaited(_loadSystemPipSupport());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
    });
  }

  Future<void> _open([Uri? overrideUrl]) async {
    if (mounted) setState(() => _error = null);
    try {
      await _player.open(
        Media((overrideUrl ?? widget.url).toString()),
        play: false,
      );
      if (widget.initialPosition > Duration.zero) {
        await _player.seek(widget.initialPosition);
      }
      if (widget.autoPlay) await _player.play();
      _showControls();
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
      // Streaming playback remains authoritative; cache is opportunistic.
    } finally {
      if (mounted) setState(() => _caching = false);
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _playbackLease?.release();
    unawaited(_playingSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_volumeSubscription?.cancel());
    unawaited(_rateSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    _keyboardFocus.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      focusNode: _keyboardFocus,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: MouseRegion(
            onHover: (_) => _showControls(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showControls,
              onDoubleTap: _toggleFullscreen,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_error == null)
                    Video(
                      key: _videoKey,
                      controller: _controller,
                      controls: NoVideoControls,
                      fit: BoxFit.contain,
                      fill: Colors.black,
                    )
                  else
                    _errorView(),
                  AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: _controlsOverlay(),
                    ),
                  ),
                  if (_caching && _cacheProgress > 0 && _cacheProgress < 1)
                    Positioned(
                      top: 58,
                      right: 16,
                      child: _statusChip(
                        '缓存 ${(100 * _cacheProgress).round()}%',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_error!, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('video-viewer-retry'),
          onPressed: _retryOpen,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _controlsOverlay() {
    final durationMs = _duration.inMilliseconds;
    final progress = durationMs <= 0
        ? 0.0
        : (_position.inMilliseconds / durationMs).clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0x88000000),
            Color(0x00000000),
            Color(0xAA000000),
          ],
          stops: <double>[0, 0.48, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 10,
            top: 8,
            child: _roundButton(
              key: const Key('video-viewer-close'),
              tooltip: '关闭',
              onPressed: _closeOrExitFullscreen,
              icon: _fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.close_rounded,
            ),
          ),
          Positioned(
            right: 10,
            top: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onPictureInPicture != null || _systemPipSupported) ...[
                  _roundButton(
                    key: const Key('video-viewer-pip'),
                    tooltip: '悬浮小窗',
                    onPressed: _openPictureInPicture,
                    icon: Icons.picture_in_picture_alt_rounded,
                  ),
                  const SizedBox(width: 8),
                ],
                _roundButton(
                  key: const Key('video-viewer-share'),
                  tooltip: '分享视频',
                  onPressed: _sharing ? null : _share,
                  icon: Icons.share_rounded,
                  progress: _sharing,
                ),
                const SizedBox(width: 8),
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
          Positioned(
            left: 14,
            right: 14,
            bottom: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white30,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white12,
                  ),
                  child: Slider(
                    key: const Key('video-viewer-seek'),
                    value: progress,
                    onChanged: durationMs <= 0 ? null : _seekFraction,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      key: const Key('video-viewer-play-pause'),
                      tooltip: _playing ? '暂停' : '播放',
                      onPressed: _togglePlay,
                      color: Colors.white,
                      icon: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      key: const Key('video-viewer-time'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      key: const Key('video-viewer-mute'),
                      tooltip: _muted ? '取消静音' : '静音',
                      onPressed: _toggleMute,
                      color: Colors.white,
                      icon: Icon(
                        _muted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                      ),
                    ),
                    if (_desktop)
                      SizedBox(
                        width: 92,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                            ),
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white30,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            key: const Key('video-viewer-volume'),
                            value: _volume.clamp(0, 100),
                            max: 100,
                            onChanged: _setVolume,
                          ),
                        ),
                      ),
                    PopupMenuButton<double>(
                      key: const Key('video-viewer-rate'),
                      tooltip: '倍速',
                      initialValue: _rate,
                      onSelected: _setRate,
                      itemBuilder: (_) => const <PopupMenuEntry<double>>[
                        PopupMenuItem(value: 0.5, child: Text('0.5×')),
                        PopupMenuItem(value: 1.0, child: Text('1×')),
                        PopupMenuItem(value: 1.25, child: Text('1.25×')),
                        PopupMenuItem(value: 1.5, child: Text('1.5×')),
                        PopupMenuItem(value: 2.0, child: Text('2×')),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        child: Text(
                          '${_rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 0 : 2)}×',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('video-viewer-fullscreen'),
                      tooltip: _fullscreen ? '退出全屏' : '全屏',
                      onPressed: _toggleFullscreen,
                      color: Colors.white,
                      icon: Icon(
                        _fullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                      ),
                    ),
                  ],
                ),
                if (_saving && _saveProgress > 0 && _saveProgress < 1)
                  LinearProgressIndicator(
                    value: _saveProgress,
                    minHeight: 2,
                    backgroundColor: Colors.white24,
                    color: Colors.white,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekRelative(const Duration(seconds: -5)));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekRelative(const Duration(seconds: 5)));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        unawaited(_toggleFullscreen());
      } else {
        Navigator.maybePop(context);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _togglePlay() async {
    _showControls();
    await _player.playOrPause();
  }

  Future<void> _seekFraction(double fraction) async {
    if (_duration <= Duration.zero) return;
    await _player.seek(
      Duration(
        milliseconds: (_duration.inMilliseconds * fraction).round(),
      ),
    );
    _showControls();
  }

  Future<void> _seekRelative(Duration delta) async {
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    await _player.seek(target);
    _showControls();
  }

  Future<void> _toggleMute() async {
    if (_muted) {
      await _player.setVolume(_volume <= 0 ? 100 : _volume);
    } else {
      await _player.setVolume(0);
    }
    _showControls();
  }

  void _setVolume(double value) {
    unawaited(_player.setVolume(value));
    _showControls();
  }

  void _setRate(double value) {
    unawaited(_player.setRate(value));
    _showControls();
  }

  Future<void> _toggleFullscreen() async {
    try {
      final video = _videoKey.currentState;
      if (video == null) throw StateError('video state unavailable');
      if (_fullscreen) {
        await video.exitFullscreen();
      } else {
        await video.enterFullscreen();
      }
      if (mounted) setState(() => _fullscreen = !_fullscreen);
    } catch (_) {
      if (mounted) _show('当前平台无法切换全屏。');
    }
    _showControls();
  }

  void _closeOrExitFullscreen() {
    if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _loadSystemPipSupport() async {
    final supported = await PictureInPictureService.shared.isSupported();
    if (mounted) setState(() => _systemPipSupported = supported);
  }

  Future<void> _openPictureInPicture() async {
    final callback = widget.onPictureInPicture;
    try {
      if (callback != null) {
        await callback(_position, _playing);
        return;
      }
      if (_systemPipSupported) {
        final entered = await PictureInPictureService.shared.enter();
        if (!entered && mounted) _show('系统拒绝进入画中画。');
      }
    } catch (_) {
      if (mounted) _show('悬浮小窗启动失败。');
    }
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (mounted && !_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_playing) return;
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
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

  Widget _statusChip(String text) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xAA000000),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70, fontSize: 11),
      ),
    ),
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

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final message = await _actions.shareVideo(
        url: await _resolveRemoteUrl(),
        mimeType: widget.mimeType,
        suggestedName: widget.fileName,
      );
      if (mounted) _show(message);
    } catch (_) {
      if (mounted) _show('视频分享失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<Uri> _resolveRemoteUrl() async {
    final resolver = widget.remoteUrlResolver;
    return resolver == null ? widget.url : resolver();
  }

  String _formatDuration(Duration value) {
    final seconds = value.inSeconds.clamp(0, 24 * 60 * 60 - 1);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final rest = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
    }
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  void _show(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
