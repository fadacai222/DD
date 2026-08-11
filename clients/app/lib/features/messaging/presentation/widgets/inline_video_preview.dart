import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../theme/app_theme.dart';

final class InlineVideoPlaybackArbiter extends ChangeNotifier {
  InlineVideoPlaybackArbiter._();

  static final InlineVideoPlaybackArbiter shared =
      InlineVideoPlaybackArbiter._();

  String? _activeId;
  String? get activeId => _activeId;

  void activate(String id) {
    if (_activeId == id) return;
    _activeId = id;
    notifyListeners();
  }

  void release(String id) {
    if (_activeId != id) return;
    _activeId = null;
    notifyListeners();
  }
}

class InlineVideoPreview extends StatefulWidget {
  const InlineVideoPreview({
    super.key,
    required this.playbackId,
    required this.posterBytes,
    required this.declaredDuration,
    required this.sourceResolver,
    required this.onOpenFull,
    this.scrollListenable,
  });

  final String playbackId;
  final Uint8List posterBytes;
  final Duration declaredDuration;
  final Future<Uri> Function() sourceResolver;
  final VoidCallback onOpenFull;
  final Listenable? scrollListenable;

  @override
  State<InlineVideoPreview> createState() => _InlineVideoPreviewState();
}

class _InlineVideoPreviewState extends State<InlineVideoPreview> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorSubscription;
  bool _playing = false;
  bool _muted = false;
  bool _loading = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Duration get _effectiveDuration =>
      _duration > Duration.zero ? _duration : widget.declaredDuration;

  @override
  void initState() {
    super.initState();
    InlineVideoPlaybackArbiter.shared.addListener(_handleArbiterChanged);
    widget.scrollListenable?.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant InlineVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollListenable != widget.scrollListenable) {
      oldWidget.scrollListenable?.removeListener(_handleScroll);
      widget.scrollListenable?.addListener(_handleScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollListenable?.removeListener(_handleScroll);
    InlineVideoPlaybackArbiter.shared.removeListener(_handleArbiterChanged);
    InlineVideoPlaybackArbiter.shared.release(widget.playbackId);
    unawaited(_playingSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  void _handleArbiterChanged() {
    if (InlineVideoPlaybackArbiter.shared.activeId == widget.playbackId) return;
    final player = _player;
    if (player != null && _playing) unawaited(player.pause());
  }

  void _handleScroll() {
    if (!_playing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_playing) return;
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
      if (visibleHeight < render.size.height * 0.35) {
        unawaited(_player?.pause());
      }
    });
  }

  Future<void> _toggle() async {
    if (_loading) return;
    final player = _player;
    if (player != null) {
      InlineVideoPlaybackArbiter.shared.activate(widget.playbackId);
      await player.playOrPause();
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final nextPlayer = Player();
      final nextController = VideoController(
        nextPlayer,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );
      _player = nextPlayer;
      _controller = nextController;
      _playingSubscription = nextPlayer.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
      });
      _positionSubscription = nextPlayer.stream.position.listen((value) {
        if (mounted) setState(() => _position = value);
      });
      _durationSubscription = nextPlayer.stream.duration.listen((value) {
        if (mounted) setState(() => _duration = value);
      });
      _errorSubscription = nextPlayer.stream.error.listen((_) {
        if (mounted) setState(() => _failed = true);
      });
      final source = await widget.sourceResolver();
      if (!mounted) return;
      InlineVideoPlaybackArbiter.shared.activate(widget.playbackId);
      await nextPlayer.open(Media(source.toString()), play: true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleMute() async {
    final player = _player;
    if (player == null) return;
    final next = !_muted;
    await player.setVolume(next ? 0 : 100);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _seek(double value) async {
    final player = _player;
    final duration = _effectiveDuration;
    if (player == null || duration <= Duration.zero) return;
    await player.seek(
      Duration(milliseconds: (duration.inMilliseconds * value).round()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final duration = _effectiveDuration;
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final remaining = duration > _position ? duration - _position : Duration.zero;
    return Material(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
        if (_controller == null)
          Image.memory(
            widget.posterBytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          )
        else
          Video(
            controller: _controller!,
            controls: NoVideoControls,
            fit: BoxFit.cover,
            fill: Colors.black,
          ),
        Positioned.fill(
          child: GestureDetector(
            key: Key('inline-video-toggle-${widget.playbackId}'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            onDoubleTap: widget.onOpenFull,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _playing ? 0 : 1,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Color(0x99000000),
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _loading
                    ? const SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        _failed
                            ? Icons.refresh_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 7,
          top: 7,
          child: _chip(_formatDuration(remaining)),
        ),
        Positioned(
          right: 6,
          top: 5,
          child: IconButton(
            key: Key('inline-video-mute-${widget.playbackId}'),
            tooltip: _muted ? '取消静音' : '静音',
            onPressed: _player == null ? null : _toggleMute,
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.52),
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white54,
              minimumSize: const Size(34, 34),
              padding: EdgeInsets.zero,
            ),
            icon: Icon(
              _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 18,
            ),
          ),
        ),
        Positioned(
          left: 7,
          right: 7,
          bottom: 3,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white38,
              thumbColor: Colors.white,
            ),
            child: Slider(
              key: Key('inline-video-progress-${widget.playbackId}'),
              value: progress,
              onChanged: _player == null ? null : _seek,
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _chip(String text) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(DdRadii.pill),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    ),
  );

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
}
