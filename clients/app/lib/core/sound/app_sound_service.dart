import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'app_sound_source.dart';

abstract interface class AppSoundBackend {
  Future<void> playCall(Uint8List bytes, {required bool loop, double volume});
  Future<void> stopCall();
  Future<void> playEffect(Uint8List bytes, {double volume});
  Future<void> stopEffect();
  Future<void> dispose();
}

final class AudioPlayersSoundBackend implements AppSoundBackend {
  final AudioPlayer _callPlayer = AudioPlayer();
  final AudioPlayer _effectPlayer = AudioPlayer();
  mk.Player? _callMediaKitPlayer;
  mk.Player? _effectMediaKitPlayer;

  @override
  Future<void> playCall(
    Uint8List bytes, {
    required bool loop,
    double volume = 0.35,
  }) async {
    await _callPlayer.stop();
    await _callPlayer.setReleaseMode(
      loop ? ReleaseMode.loop : ReleaseMode.stop,
    );
    final source = await createAppSoundSource(bytes);
    if (source is DeviceFileSource) {
      await _callPlayer.stop();
      final player = _callMediaKitPlayer ??= mk.Player();
      await player.stop();
      await player.setPlaylistMode(
        loop ? mk.PlaylistMode.single : mk.PlaylistMode.none,
      );
      await player.setVolume((volume * 100).clamp(0, 100).toDouble());
      await player.open(mk.Media(source.path), play: true);
      return;
    }
    await _callMediaKitPlayer?.stop();
    await _callPlayer.play(source, volume: volume);
  }

  @override
  Future<void> stopCall() async {
    await _callPlayer.stop();
    await _callMediaKitPlayer?.stop();
  }

  @override
  Future<void> playEffect(Uint8List bytes, {double volume = 0.32}) async {
    await _effectPlayer.stop();
    await _effectPlayer.setReleaseMode(ReleaseMode.stop);
    final source = await createAppSoundSource(bytes);
    if (source is DeviceFileSource) {
      await _effectPlayer.stop();
      final player = _effectMediaKitPlayer ??= mk.Player();
      await player.stop();
      await player.setPlaylistMode(mk.PlaylistMode.none);
      await player.setVolume((volume * 100).clamp(0, 100).toDouble());
      await player.open(mk.Media(source.path), play: true);
      return;
    }
    await _effectMediaKitPlayer?.stop();
    await _effectPlayer.play(source, volume: volume);
  }

  @override
  Future<void> stopEffect() async {
    await _effectPlayer.stop();
    await _effectMediaKitPlayer?.stop();
  }

  @override
  Future<void> dispose() async {
    await _callPlayer.dispose();
    await _effectPlayer.dispose();
    await _callMediaKitPlayer?.dispose();
    await _effectMediaKitPlayer?.dispose();
  }
}

enum AppSoundCue {
  outgoingRingback,
  incomingRingtone,
  callConnected,
  callEnded,
  messageNotification,
}

final class AppSoundService {
  AppSoundService({AppSoundBackend? backend})
    : _backend = backend ?? AudioPlayersSoundBackend();

  static final AppSoundService shared = AppSoundService();

  final AppSoundBackend _backend;
  AppSoundCue? _activeCallCue;
  DateTime? _lastMessageSoundAt;
  bool _disposed = false;

  AppSoundCue? get activeCallCue => _activeCallCue;

  Future<void> playOutgoingRingback() => _playCallLoop(
    AppSoundCue.outgoingRingback,
    AppToneFactory.outgoingRingback,
    volume: 0.27,
  );

  Future<void> playIncomingRingtone() => _playCallLoop(
    AppSoundCue.incomingRingtone,
    AppToneFactory.incomingRingtone,
    volume: 0.42,
  );

  Future<void> stopCallSounds() async {
    if (_disposed) return;
    _activeCallCue = null;
    try {
      await _backend.stopCall();
    } catch (_) {
      // Sounds are non-critical; never break a call state transition.
    }
  }

  Future<void> playCallConnected() async {
    await stopCallSounds();
    await _playEffect(
      AppSoundCue.callConnected,
      AppToneFactory.callConnected,
      volume: 0.26,
    );
  }

  Future<void> playCallEnded() async {
    await stopCallSounds();
    await _playEffect(
      AppSoundCue.callEnded,
      AppToneFactory.callEnded,
      volume: 0.3,
    );
  }

  Future<void> playMessageNotification() async {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _lastMessageSoundAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 180)) {
      return;
    }
    _lastMessageSoundAt = now;
    await _playEffect(
      AppSoundCue.messageNotification,
      AppToneFactory.messageNotification,
      volume: 0.25,
    );
  }

  Future<void> _playCallLoop(
    AppSoundCue cue,
    Uint8List bytes, {
    required double volume,
  }) async {
    if (_disposed || _activeCallCue == cue) return;
    _activeCallCue = cue;
    try {
      await _backend.playCall(bytes, loop: true, volume: volume);
    } catch (_) {
      if (_activeCallCue == cue) _activeCallCue = null;
    }
  }

  Future<void> _playEffect(
    AppSoundCue cue,
    Uint8List bytes, {
    required double volume,
  }) async {
    if (_disposed) return;
    try {
      await _backend.playEffect(bytes, volume: volume);
    } catch (_) {
      // UI and messaging must remain usable even if an audio device disappears.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _activeCallCue = null;
    try {
      await _backend.dispose();
    } catch (_) {}
  }
}

/// Original DD-generated tones. No third-party audio files or proprietary app
/// sounds are embedded. The resulting PCM WAVs are deterministic and tiny.
abstract final class AppToneFactory {
  static Uint8List? _outgoingRingback;
  static Uint8List? _incomingRingtone;
  static Uint8List? _callConnected;
  static Uint8List? _callEnded;
  static Uint8List? _messageNotification;

  static Uint8List get outgoingRingback => _outgoingRingback ??= _build(
    durationMs: 3600,
    segments: const [
      _ToneSegment(0, 900, [440, 480], 0.7),
      _ToneSegment(900, 3600, [], 0),
    ],
  );

  static Uint8List get incomingRingtone => _incomingRingtone ??= _build(
    durationMs: 2800,
    segments: const [
      _ToneSegment(0, 420, [659, 784], 0.72),
      _ToneSegment(420, 650, [], 0),
      _ToneSegment(650, 1080, [659, 880], 0.68),
      _ToneSegment(1080, 2800, [], 0),
    ],
  );

  static Uint8List get callConnected => _callConnected ??= _build(
    durationMs: 190,
    segments: const [
      _ToneSegment(0, 90, [660], 0.58),
      _ToneSegment(90, 190, [880], 0.54),
    ],
  );

  static Uint8List get callEnded => _callEnded ??= _build(
    durationMs: 320,
    segments: const [
      _ToneSegment(0, 150, [620], 0.58),
      _ToneSegment(150, 320, [430], 0.54),
    ],
  );

  static Uint8List get messageNotification => _messageNotification ??= _build(
    durationMs: 210,
    segments: const [
      _ToneSegment(0, 85, [740], 0.46),
      _ToneSegment(85, 210, [988], 0.4),
    ],
  );

  static Uint8List _build({
    required int durationMs,
    required List<_ToneSegment> segments,
  }) {
    const sampleRate = 22050;
    final sampleCount = sampleRate * durationMs ~/ 1000;
    final pcmBytes = sampleCount * 2;
    final data = ByteData(44 + pcmBytes);

    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + pcmBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, pcmBytes, Endian.little);

    for (var i = 0; i < sampleCount; i++) {
      final ms = i * 1000 / sampleRate;
      final segment = segments.cast<_ToneSegment?>().firstWhere(
        (candidate) =>
            candidate != null &&
            ms >= candidate.startMs &&
            ms < candidate.endMs,
        orElse: () => null,
      );
      var normalized = 0.0;
      if (segment != null && segment.frequencies.isNotEmpty) {
        final localMs = ms - segment.startMs;
        final duration = math.max(1.0, segment.endMs - segment.startMs);
        final attack = (localMs / 24).clamp(0.0, 1.0);
        final release = ((duration - localMs) / 42).clamp(0.0, 1.0);
        final envelope = math.min(attack, release) * segment.gain;
        for (final frequency in segment.frequencies) {
          normalized += math.sin(2 * math.pi * frequency * (i / sampleRate));
        }
        normalized = normalized / segment.frequencies.length * envelope;
      }
      final sample = (normalized * 11000).round().clamp(-32767, 32767);
      data.setInt16(44 + i * 2, sample, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

final class _ToneSegment {
  const _ToneSegment(this.startMs, this.endMs, this.frequencies, this.gain);

  final int startMs;
  final int endMs;
  final List<double> frequencies;
  final double gain;
}
