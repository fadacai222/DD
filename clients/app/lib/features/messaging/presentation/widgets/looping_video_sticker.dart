import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../core/logging/client_log.dart';
import '../../../../core/performance/app_performance_store.dart';

class LoopingVideoSticker extends StatefulWidget {
  const LoopingVideoSticker({
    super.key,
    required this.playbackId,
    required this.sourceResolver,
    this.scrollListenable,
  });

  final String playbackId;
  final Future<Uri> Function() sourceResolver;
  final Listenable? scrollListenable;

  @override
  State<LoopingVideoSticker> createState() => _LoopingVideoStickerState();
}

class _LoopingVideoStickerState extends State<LoopingVideoSticker> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSubscription;
  Animation<double>? _routeAnimation;
  bool _loading = false;
  bool _failed = false;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    widget.scrollListenable?.addListener(_handleVisibilitySignal);
    _scheduleVisibilitySync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextAnimation = ModalRoute.of(context)?.animation;
    if (!identical(nextAnimation, _routeAnimation)) {
      _routeAnimation?.removeListener(_handleVisibilitySignal);
      _routeAnimation = nextAnimation;
      _routeAnimation?.addListener(_handleVisibilitySignal);
    }
    _scheduleVisibilitySync();
  }

  @override
  void didUpdateWidget(covariant LoopingVideoSticker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollListenable != widget.scrollListenable) {
      oldWidget.scrollListenable?.removeListener(_handleVisibilitySignal);
      widget.scrollListenable?.addListener(_handleVisibilitySignal);
    }
    if (oldWidget.playbackId != widget.playbackId) {
      unawaited(_resetAndStart());
    }
  }

  @override
  void dispose() {
    widget.scrollListenable?.removeListener(_handleVisibilitySignal);
    _routeAnimation?.removeListener(_handleVisibilitySignal);
    unawaited(_errorSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  void _handleVisibilitySignal() => _scheduleVisibilitySync();

  void _scheduleVisibilitySync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncVisibility();
    });
  }

  void _syncVisibility() {
    if (!mounted) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;
    final topLeft = render.localToGlobal(Offset.zero);
    final bottomRight = render.localToGlobal(
      Offset(render.size.width, render.size.height),
    );
    final screen = MediaQuery.sizeOf(context);
    final visibleHeight =
        (bottomRight.dy.clamp(0.0, screen.height) -
                topLeft.dy.clamp(0.0, screen.height))
            .clamp(0.0, render.size.height);
    final nextVisible = visibleHeight >= render.size.height * 0.30;
    if (_visible != nextVisible) _visible = nextVisible;
    if (_visible) {
      unawaited(_ensurePlaying());
    } else {
      unawaited(_player?.pause());
    }
  }

  Future<void> _resetAndStart() async {
    final previous = _player;
    _player = null;
    _controller = null;
    await _errorSubscription?.cancel();
    _errorSubscription = null;
    await previous?.dispose();
    if (mounted) {
      setState(() {
        _failed = false;
        _loading = false;
      });
      _syncVisibility();
    }
  }

  Future<void> _ensurePlaying() async {
    if (!mounted || !_visible || _loading || _failed) return;
    final existing = _player;
    if (existing != null) {
      if (!existing.state.playing) await existing.play();
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final source = await widget.sourceResolver().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('视频表情地址解析超时。'),
      );
      if (!mounted || !_visible) return;

      final player = Player();
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration:
              AppPerformanceStore.shared.hardwareVideoDecoding,
        ),
      );
      _player = player;
      _controller = controller;
      _errorSubscription = player.stream.error.listen((error) {
        unawaited(
          ClientLog.error(
            'Video sticker playback error: ${widget.playbackId}',
            error: error,
          ),
        );
        if (mounted) setState(() => _failed = true);
      });
      await player.setVolume(0);
      await player.setPlaylistMode(PlaylistMode.single);
      await player
          .open(Media(source.toString()), play: true)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('视频表情播放器打开超时。'),
          );
    } catch (error, stackTrace) {
      unawaited(
        ClientLog.error(
          'Video sticker start failed: ${widget.playbackId}',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null && !_failed) {
      return Video(
        controller: controller,
        controls: NoVideoControls,
        fit: BoxFit.contain,
        fill: Colors.transparent,
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _failed ? () => unawaited(_resetAndStart()) : null,
        child: Center(
          child: _failed
              ? const Icon(Icons.refresh_rounded, size: 30)
              : const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      ),
    );
  }
}
