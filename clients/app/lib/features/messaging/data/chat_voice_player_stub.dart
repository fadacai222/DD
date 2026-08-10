import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'voice_playback_source.dart';

final class ChatVoicePlayer {
  ChatVoicePlayer() {
    _subscriptions.add(
      _player.onPlayerStateChanged.listen((state) {
        final playing = state == PlayerState.playing;
        _isPlaying = playing;
        if (!_playingController.isClosed) _playingController.add(playing);
        if (state == PlayerState.completed && !_completedController.isClosed) {
          _completedController.add(null);
        }
      }),
    );
    _subscriptions.add(
      _player.onPositionChanged.listen((value) {
        if (!_positionController.isClosed) _positionController.add(value);
      }),
    );
    _subscriptions.add(
      _player.onDurationChanged.listen((value) {
        if (!_durationController.isClosed) _durationController.add(value);
      }),
    );
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<void> _completedController =
      StreamController<void>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;
  Stream<bool> get playing => _playingController.stream;
  Stream<void> get completed => _completedController.stream;
  Stream<Duration> get position => _positionController.stream;
  Stream<Duration> get duration => _durationController.stream;

  Future<void> play({
    required Uint8List bytes,
    required String namespace,
    required String mediaId,
    String? mimeType,
    double rate = 1,
  }) async {
    await _player.stop();
    await _player.setPlaybackRate(rate);
    final source = await createVoicePlaybackSource(
      bytes: bytes,
      namespace: namespace,
      mediaId: mediaId,
      mimeType: mimeType,
    );
    await _player.play(source);
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.resume();
  Future<void> stop() => _player.stop();
  Future<void> setRate(double rate) => _player.setPlaybackRate(rate);

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
    await _playingController.close();
    await _completedController.close();
    await _positionController.close();
    await _durationController.close();
  }
}
