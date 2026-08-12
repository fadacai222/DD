import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('1:1 call keeps iOS camera lifecycle, speaker and reconnect wiring', () {
    final page = File(
      'lib/features/calls/presentation/chat_call_page.dart',
    ).readAsStringSync();
    final media = File(
      'lib/features/calls/presentation/call_debug_controller.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/features/calls/presentation/two_party_call_controller.dart',
    ).readAsStringSync();

    expect(page, contains('with WidgetsBindingObserver'));
    expect(page, contains('setCameraSuspended'));
    expect(page, contains('mediaController.toggleSpeaker'));
    expect(page, contains('TargetPlatform.android'));
    expect(page, isNot(contains('TargetPlatform.iOS')));

    expect(media, contains('setMicrophoneEnabled'));
    expect(media, contains('setCameraEnabled'));
    expect(media, contains('setCameraPosition'));
    expect(media, contains('RoomReconnectingEvent'));
    expect(media, contains('RoomReconnectedEvent'));
    expect(media, contains('CallMediaConnectionState.reconnecting'));
    expect(controller, contains('_scheduleMediaRecovery'));
    expect(controller, contains('mediaRecoveryDelays'));
  });

  test('group call keeps real LiveKit controls and background camera suspension', () {
    final source = File(
      'lib/features/calls/presentation/group_call_page.dart',
    ).readAsStringSync();

    expect(source, contains('local.setMicrophoneEnabled(true)'));
    expect(source, contains('local.setCameraEnabled(true)'));
    expect(source, contains('_room.localParticipant?.setMicrophoneEnabled(next)'));
    expect(source, contains('_room.localParticipant?.setCameraEnabled(next)'));
    expect(source, contains('_audioSession.setSpeakerPreferred(next)'));
    expect(source, contains('RoomReconnectingEvent'));
    expect(source, contains('RoomReconnectedEvent'));
    expect(source, contains('AppLifecycleState.paused'));
    expect(source, contains('AppLifecycleState.resumed'));
    expect(source, contains('remoteParticipants'));
  });

  test('voice record/playback stays cross-platform and call-safe', () {
    final recorder = File(
      'lib/core/media/chat_voice_recorder.dart',
    ).readAsStringSync();
    final player = File(
      'lib/features/messaging/data/chat_voice_player_io.dart',
    ).readAsStringSync();

    expect(recorder, contains('_recorder.hasPermission()'));
    expect(recorder, contains('_recording = true'));
    expect(recorder, contains('_resetSession()'));
    expect(recorder, isNot(contains('Platform.isAndroid')));
    expect(recorder, isNot(contains('Platform.isWindows')));

    expect(player, contains('Future<void> pause()'));
    expect(player, contains('Future<void> resume()'));
    expect(player, contains('_ensureCallAudioAvailable()'));
    expect(player, isNot(contains('Platform.isIOS')));
  });
}
