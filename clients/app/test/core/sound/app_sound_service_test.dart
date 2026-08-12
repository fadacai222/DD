import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/sound/app_audio_activity.dart';
import 'package:im_client/core/sound/app_sound_service.dart';

void main() {
  test('generated DD tones are valid PCM WAV files', () {
    for (final bytes in <Uint8List>[
      AppToneFactory.outgoingRingback,
      AppToneFactory.incomingRingtone,
      AppToneFactory.callConnected,
      AppToneFactory.callEnded,
      AppToneFactory.messageNotification,
    ]) {
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(bytes.length, greaterThan(1000));
    }
  });

  test(
    'call sounds switch cleanly and stop before connect/end effects',
    () async {
      final backend = _FakeSoundBackend();
      final service = AppSoundService(backend: backend);
      addTearDown(service.dispose);

      await service.playOutgoingRingback();
      await service.playOutgoingRingback();
      expect(backend.callPlays, 1);
      expect(service.activeCallCue, AppSoundCue.outgoingRingback);

      await service.playIncomingRingtone();
      expect(backend.callPlays, 2);
      expect(service.activeCallCue, AppSoundCue.incomingRingtone);

      await service.playCallConnected();
      expect(backend.callStops, greaterThanOrEqualTo(1));
      expect(backend.effectPlays, 1);
      expect(service.activeCallCue, isNull);

      await service.playCallEnded();
      expect(backend.effectPlays, 2);
      expect(service.activeCallCue, isNull);
    },
  );

  test('message notification bursts are debounced', () async {
    final backend = _FakeSoundBackend();
    final service = AppSoundService(backend: backend);
    addTearDown(service.dispose);

    await service.playMessageNotification();
    await service.playMessageNotification();
    expect(backend.effectPlays, 1);
  });

  test('message sounds do not steal the audio session from an active call', () async {
    final backend = _FakeSoundBackend();
    final activity = AppAudioActivity();
    final service = AppSoundService(backend: backend, audioActivity: activity);
    final owner = Object();
    addTearDown(service.dispose);

    activity.acquire(owner);
    await service.playMessageNotification();

    expect(backend.effectPlays, 0);
    activity.release(owner);
    await service.playMessageNotification();
    expect(backend.effectPlays, 1);
  });
}

final class _FakeSoundBackend implements AppSoundBackend {
  int callPlays = 0;
  int callStops = 0;
  int effectPlays = 0;

  @override
  Future<void> playCall(
    Uint8List bytes, {
    required bool loop,
    double volume = 0.35,
  }) async {
    callPlays++;
    expect(loop, isTrue);
    expect(bytes, isNotEmpty);
  }

  @override
  Future<void> stopCall() async => callStops++;

  @override
  Future<void> playEffect(Uint8List bytes, {double volume = 0.32}) async {
    effectPlays++;
    expect(bytes, isNotEmpty);
  }

  @override
  Future<void> stopEffect() async {}

  @override
  Future<void> dispose() async {}
}
