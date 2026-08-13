import 'dart:async';

import 'voice_playback_source.dart';

abstract interface class VoicePlaybackEngine {
  bool get isPlaying;
  Stream<bool> get playing;
  Stream<void> get completed;
  Stream<Duration> get position;
  Stream<Duration> get duration;

  Future<void> playSource(VoicePlaybackSource source, {double rate = 1});
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> setRate(double rate);
}
