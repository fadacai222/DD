import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final class DesktopVideoPipRequest {
  const DesktopVideoPipRequest({
    required this.id,
    required this.title,
    required this.sourceResolver,
    required this.initialPosition,
    required this.initialPlaying,
    required this.onRestore,
  });

  final String id;
  final String title;
  final Future<Uri> Function() sourceResolver;
  final Duration initialPosition;
  final bool initialPlaying;
  final Future<void> Function(Duration position, bool playing) onRestore;
}

final class DesktopVideoPipController extends ChangeNotifier {
  DesktopVideoPipController._();

  static final DesktopVideoPipController shared = DesktopVideoPipController._();

  DesktopVideoPipRequest? _request;
  DesktopVideoPipRequest? get request => _request;

  void open(DesktopVideoPipRequest request) {
    _request = request;
    notifyListeners();
  }

  void close() {
    if (_request == null) return;
    _request = null;
    notifyListeners();
  }
}

class DesktopVideoPipHost extends StatelessWidget {
  const DesktopVideoPipHost({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DesktopVideoPipController.shared,
      builder: (context, _) {
        final request = DesktopVideoPipController.shared.request;
        if (request == null) return const SizedBox.shrink();
        return _DesktopVideoPipPlayer(
          key: ValueKey('desktop-pip-${request.id}'),
          request: request,
        );
      },
    );
  }
}

class _DesktopVideoPipPlayer extends StatefulWidget {
  const _DesktopVideoPipPlayer({super.key, required this.request});

  final DesktopVideoPipRequest request;

  @override
  State<_DesktopVideoPipPlayer> createState() => _DesktopVideoPipPlayerState();
}

class _DesktopVideoPipPlayerState extends State<_DesktopVideoPipPlayer> {
  late final Player _player;
  late final VideoController _video;
  Offset? _offset;
  bool _loading = true;
  bool _playing = false;
  bool _muted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _playingSubscription = _player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
    _positionSubscription = _player.stream.position.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _durationSubscription = _player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final source = await widget.request.sourceResolver();
      await _player.open(Media(source.toString()), play: false);
      if (widget.request.initialPosition > Duration.zero) {
        await _player.seek(widget.request.initialPosition);
      }
      if (widget.request.initialPlaying) await _player.play();
    } catch (_) {
      if (mounted) setState(() => _error = '小窗播放失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    unawaited(_playingSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const width = 320.0;
        const height = 206.0;
        final fallback = Offset(
          (constraints.maxWidth - width - 16).clamp(8.0, double.infinity),
          16,
        );
        final raw = _offset ?? fallback;
        final position = Offset(
          raw.dx.clamp(8.0, (constraints.maxWidth - width - 8).clamp(8.0, double.infinity)),
          raw.dy.clamp(8.0, (constraints.maxHeight - height - 8).clamp(8.0, double.infinity)),
        );
        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              width: width,
              height: height,
              child: Material(
                key: const Key('desktop-video-pip'),
                elevation: 18,
                color: Colors.black,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(13),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    GestureDetector(
                      key: const Key('desktop-video-pip-drag'),
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) => setState(() {
                        _offset = position + details.delta;
                      }),
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.only(left: 11, right: 4),
                        color: const Color(0xFF202020),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.drag_indicator_rounded,
                              size: 16,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                widget.request.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            IconButton(
                              key: const Key('desktop-video-pip-restore'),
                              tooltip: '恢复到主窗口',
                              visualDensity: VisualDensity.compact,
                              onPressed: _restore,
                              color: Colors.white70,
                              icon: const Icon(Icons.open_in_full_rounded, size: 16),
                            ),
                            IconButton(
                              key: const Key('desktop-video-pip-close'),
                              tooltip: '关闭小窗',
                              visualDensity: VisualDensity.compact,
                              onPressed: DesktopVideoPipController.shared.close,
                              color: Colors.white70,
                              icon: const Icon(Icons.close_rounded, size: 17),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_error != null)
                            Center(
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            )
                          else if (_loading)
                            const Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            )
                          else
                            Video(
                              controller: _video,
                              controls: NoVideoControls,
                              fit: BoxFit.contain,
                              fill: Colors.black,
                            ),
                          Positioned(
                            left: 6,
                            right: 6,
                            bottom: 4,
                            child: Row(
                              children: [
                                IconButton(
                                  key: const Key('desktop-video-pip-play'),
                                  onPressed: _player.playOrPause,
                                  color: Colors.white,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    _playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                ),
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: _duration.inMilliseconds <= 0
                                        ? null
                                        : (_position.inMilliseconds /
                                                  _duration.inMilliseconds)
                                              .clamp(0.0, 1.0),
                                    minHeight: 2,
                                    color: Colors.white,
                                    backgroundColor: Colors.white30,
                                  ),
                                ),
                                IconButton(
                                  key: const Key('desktop-video-pip-mute'),
                                  onPressed: _toggleMute,
                                  color: Colors.white,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    _muted
                                        ? Icons.volume_off_rounded
                                        : Icons.volume_up_rounded,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    await _player.setVolume(next ? 0 : 100);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _restore() async {
    final callback = widget.request.onRestore;
    final position = _position;
    final playing = _playing;
    DesktopVideoPipController.shared.close();
    await callback(position, playing);
  }
}
