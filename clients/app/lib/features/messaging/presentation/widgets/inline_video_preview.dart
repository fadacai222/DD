import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../core/performance/app_performance_store.dart';
import '../../../../theme/app_theme.dart';

final class InlineVideoPlaybackArbiter extends ChangeNotifier {
  InlineVideoPlaybackArbiter._();

  static final InlineVideoPlaybackArbiter shared =
      InlineVideoPlaybackArbiter._();

  static const double _minimumVisibleFraction = 0.55;

  final Map<String, double> _visibleFractions = <String, double>{};
  String? _activeId;
  String? get activeId => _activeId;

  void activate(String id) {
    if (_activeId == id) return;
    _activeId = id;
    notifyListeners();
  }

  void updateVisibility(String id, double visibleFraction) {
    final nextFraction = visibleFraction.clamp(0.0, 1.0);
    if (nextFraction <= 0) {
      _visibleFractions.remove(id);
    } else {
      _visibleFractions[id] = nextFraction;
    }
    _selectMostVisible();
  }

  void removeCandidate(String id) {
    _visibleFractions.remove(id);
    if (_activeId == id) _activeId = null;
    _selectMostVisible();
  }

  void release(String id) {
    if (_activeId != id) return;
    _activeId = null;
    _selectMostVisible();
  }

  void _selectMostVisible() {
    String? bestId;
    var bestFraction = 0.0;
    for (final entry in _visibleFractions.entries) {
      if (entry.value < _minimumVisibleFraction) continue;
      if (entry.value > bestFraction) {
        bestId = entry.key;
        bestFraction = entry.value;
      }
    }

    final currentId = _activeId;
    if (currentId != null) {
      final currentFraction = _visibleFractions[currentId] ?? 0;
      if (currentFraction >= _minimumVisibleFraction &&
          currentFraction >= bestFraction - 0.05) {
        bestId = currentId;
      }
    }

    if (_activeId == bestId) return;
    _activeId = bestId;
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
    this.autoPlayWhenVisible,
    this.openFullOnTap,
  });

  final String playbackId;
  final Uint8List posterBytes;
  final Duration declaredDuration;
  final Future<Uri> Function() sourceResolver;
  final VoidCallback onOpenFull;
  final Listenable? scrollListenable;
  final bool? autoPlayWhenVisible;
  final bool? openFullOnTap;

  @override
  State<InlineVideoPreview> createState() => _InlineVideoPreviewState();
}

class _InlineVideoPreviewState extends State<InlineVideoPreview>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorSubscription;
  bool _playing = false;
  bool _muted = false;
  bool _loading = false;
  bool _visibilityCheckScheduled = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Duration get _effectiveDuration =>
      _duration > Duration.zero ? _duration : widget.declaredDuration;

  bool get _autoPlayWhenVisible =>
      AppPerformanceStore.shared.effectiveAutoPlayVideoPreviews &&
      (widget.autoPlayWhenVisible ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android));

  bool get _openFullOnTap =>
      widget.openFullOnTap ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    InlineVideoPlaybackArbiter.shared.addListener(_handleArbiterChanged);
    AppPerformanceStore.shared.addListener(_handlePerformanceChanged);
    widget.scrollListenable?.addListener(_handleViewportChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleViewportEvaluation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_autoPlayWhenVisible) return;
    if (state != AppLifecycleState.resumed) {
      InlineVideoPlaybackArbiter.shared.updateVisibility(widget.playbackId, 0);
      unawaited(_player?.pause());
      return;
    }
    _scheduleViewportEvaluation();
  }

  @override
  void didUpdateWidget(covariant InlineVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollListenable != widget.scrollListenable) {
      oldWidget.scrollListenable?.removeListener(_handleViewportChanged);
      widget.scrollListenable?.addListener(_handleViewportChanged);
    }
    if (oldWidget.autoPlayWhenVisible != widget.autoPlayWhenVisible ||
        oldWidget.playbackId != widget.playbackId) {
      InlineVideoPlaybackArbiter.shared.removeCandidate(oldWidget.playbackId);
      _scheduleViewportEvaluation();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.scrollListenable?.removeListener(_handleViewportChanged);
    InlineVideoPlaybackArbiter.shared.removeListener(_handleArbiterChanged);
    AppPerformanceStore.shared.removeListener(_handlePerformanceChanged);
    InlineVideoPlaybackArbiter.shared.removeCandidate(widget.playbackId);
    unawaited(_playingSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  void _handlePerformanceChanged() {
    if (!AppPerformanceStore.shared.effectiveAutoPlayVideoPreviews) {
      InlineVideoPlaybackArbiter.shared.updateVisibility(widget.playbackId, 0);
      unawaited(_player?.pause());
      if (mounted) setState(() {});
      return;
    }
    _scheduleViewportEvaluation();
    if (mounted) setState(() {});
  }

  void _handleArbiterChanged() {
    if (InlineVideoPlaybackArbiter.shared.activeId == widget.playbackId) {
      if (_autoPlayWhenVisible) unawaited(_ensureAutoPlayback());
      return;
    }
    final player = _player;
    if (player != null && _playing) unawaited(player.pause());
  }

  void _handleViewportChanged() => _scheduleViewportEvaluation();

  void _scheduleViewportEvaluation() {
    if (!_autoPlayWhenVisible || _visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted) return;
      _updatePlaybackCandidate();
    });
  }

  void _updatePlaybackCandidate() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if ((lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        !routeIsCurrent ||
        !TickerMode.valuesOf(context).enabled) {
      InlineVideoPlaybackArbiter.shared.updateVisibility(widget.playbackId, 0);
      return;
    }

    final render = context.findRenderObject();
    if (render is! RenderBox || !render.hasSize || render.size.isEmpty) {
      InlineVideoPlaybackArbiter.shared.updateVisibility(widget.playbackId, 0);
      return;
    }
    final viewport = Offset.zero & MediaQuery.sizeOf(context);
    final rect = render.localToGlobal(Offset.zero) & render.size;
    final intersection = rect.intersect(viewport);
    if (intersection.isEmpty) {
      InlineVideoPlaybackArbiter.shared.updateVisibility(widget.playbackId, 0);
      return;
    }
    final totalArea = rect.width * rect.height;
    final visibleArea = intersection.width * intersection.height;
    final visibleFraction = totalArea <= 0 ? 0.0 : visibleArea / totalArea;
    InlineVideoPlaybackArbiter.shared.updateVisibility(
      widget.playbackId,
      visibleFraction,
    );
  }

  Future<void> _ensureAutoPlayback() async {
    if (!_autoPlayWhenVisible || _loading || _failed) return;
    final player = _player;
    if (player != null) {
      if (!_playing &&
          InlineVideoPlaybackArbiter.shared.activeId == widget.playbackId) {
        await player.play();
      }
      return;
    }
    await _startPlayback(autoPlay: true, startMuted: true, looping: true);
  }

  Future<void> _toggle() async {
    if (_loading) return;
    final player = _player;
    if (player != null) {
      InlineVideoPlaybackArbiter.shared.activate(widget.playbackId);
      await player.playOrPause();
      return;
    }
    await _startPlayback(autoPlay: true);
  }

  Future<void> _startPlayback({
    required bool autoPlay,
    bool startMuted = false,
    bool looping = false,
  }) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final nextPlayer = Player();
      final nextController = VideoController(
        nextPlayer,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration:
              AppPerformanceStore.shared.hardwareVideoDecoding,
        ),
      );
      _player = nextPlayer;
      _controller = nextController;
      _muted = startMuted;
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
        if (!mounted) return;
        setState(() => _failed = true);
        if (_autoPlayWhenVisible) {
          InlineVideoPlaybackArbiter.shared.updateVisibility(
            widget.playbackId,
            0,
          );
        }
      });
      if (looping) await nextPlayer.setPlaylistMode(PlaylistMode.single);
      if (startMuted) await nextPlayer.setVolume(0);
      final source = await widget.sourceResolver();
      if (!mounted) return;
      final shouldPlay =
          autoPlay &&
          (!_autoPlayWhenVisible ||
              InlineVideoPlaybackArbiter.shared.activeId == widget.playbackId);
      if (!_autoPlayWhenVisible) {
        InlineVideoPlaybackArbiter.shared.activate(widget.playbackId);
      }
      await nextPlayer.open(Media(source.toString()), play: shouldPlay);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openFull() {
    if (_autoPlayWhenVisible) {
      InlineVideoPlaybackArbiter.shared.updateVisibility(widget.playbackId, 0);
      unawaited(_player?.pause());
    }
    widget.onOpenFull();
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
    final remaining = duration > _position
        ? duration - _position
        : Duration.zero;
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
              onTap: _openFullOnTap ? _openFull : _toggle,
              onDoubleTap: _openFullOnTap ? null : _openFull,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          if (!_autoPlayWhenVisible || _loading || _failed)
            IgnorePointer(
              child: Center(
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
            ),
          Positioned(left: 7, top: 7, child: _chip(_formatDuration(remaining))),
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
