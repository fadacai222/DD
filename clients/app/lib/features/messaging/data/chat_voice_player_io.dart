import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:media_kit/media_kit.dart' as mk;

import 'voice_playback_source.dart';

final class ChatVoicePlayer {
  ChatVoicePlayer() {
    if (!Platform.isWindows) {
      final player = ap.AudioPlayer();
      _audioPlayer = player;
      _subscriptions.add(
        player.onPlayerStateChanged.listen((state) {
          final playing = state == ap.PlayerState.playing;
          _isPlaying = playing;
          if (!_playingController.isClosed) _playingController.add(playing);
          if (state == ap.PlayerState.completed &&
              !_completedController.isClosed) {
            _completedController.add(null);
          }
        }),
      );
      _subscriptions.add(
        player.onPositionChanged.listen((value) {
          if (!_positionController.isClosed) _positionController.add(value);
        }),
      );
      _subscriptions.add(
        player.onDurationChanged.listen((value) {
          if (!_durationController.isClosed) _durationController.add(value);
        }),
      );
    }
  }

  mk.Player? _mediaKitPlayer;
  ap.AudioPlayer? _audioPlayer;
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

  mk.Player _ensureMediaKitPlayer() {
    final existing = _mediaKitPlayer;
    if (existing != null) return existing;
    final player = mk.Player();
    _mediaKitPlayer = player;
    _subscriptions.add(
      player.stream.playing.listen((value) {
        _isPlaying = value;
        if (!_playingController.isClosed) _playingController.add(value);
      }),
    );
    _subscriptions.add(
      player.stream.completed.listen((value) {
        if (value && !_completedController.isClosed) {
          _completedController.add(null);
        }
      }),
    );
    _subscriptions.add(
      player.stream.position.listen((value) {
        if (!_positionController.isClosed) _positionController.add(value);
      }),
    );
    _subscriptions.add(
      player.stream.duration.listen((value) {
        if (!_durationController.isClosed) _durationController.add(value);
      }),
    );
    return player;
  }

  Future<void> play({
    required Uint8List bytes,
    required String namespace,
    required String mediaId,
    String? mimeType,
    double rate = 1,
  }) async {
    if (Platform.isWindows) {
      final mediaKit = _ensureMediaKitPlayer();
      final source = await createVoicePlaybackSource(
        bytes: bytes,
        namespace: namespace,
        mediaId: mediaId,
        mimeType: mimeType,
      );
      if (source is! ap.DeviceFileSource) {
        throw StateError(
          'Windows voice playback requires a local file source.',
        );
      }
      await mediaKit.stop();
      await mediaKit.open(mk.Media(source.path), play: false);
      await mediaKit.setRate(rate);
      await mediaKit.play();
      return;
    }

    final audio = _audioPlayer!;
    await audio.stop();
    await audio.setPlaybackRate(rate);
    final source = await createVoicePlaybackSource(
      bytes: bytes,
      namespace: namespace,
      mediaId: mediaId,
      mimeType: mimeType,
    );
    await audio.play(source);
  }

  Future<void> pause() async {
    if (Platform.isWindows) {
      await _mediaKitPlayer?.pause();
      return;
    }
    await _audioPlayer?.pause();
  }

  Future<void> resume() async {
    if (Platform.isWindows) {
      await _mediaKitPlayer?.play();
      return;
    }
    await _audioPlayer?.resume();
  }

  Future<void> stop() async {
    _isPlaying = false;
    if (Platform.isWindows) {
      await _mediaKitPlayer?.stop();
      return;
    }
    await _audioPlayer?.stop();
  }

  Future<void> setRate(double rate) async {
    if (Platform.isWindows) {
      await _mediaKitPlayer?.setRate(rate);
      return;
    }
    await _audioPlayer?.setPlaybackRate(rate);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _mediaKitPlayer?.dispose();
    await _audioPlayer?.dispose();
    await _playingController.close();
    await _completedController.close();
    await _positionController.close();
    await _durationController.close();
  }
}
