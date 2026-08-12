import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/data/call_audio_session_controller.dart';

void main() {
  test('CallKit mode gates LiveKit engine until system audio activates', () async {
    final backend = _FakeCallAudioBackend();
    final controller = CallAudioSessionController(backend: backend);

    await controller.prepare(video: false, externalCallSystem: true);

    expect(controller.externalCallSystem, isTrue);
    expect(controller.speakerPreferred, isFalse);
    expect(controller.interrupted, isFalse);
    expect(backend.managementModes, [CallAudioManagementMode.externalCallSystem]);
    expect(backend.engineAvailability, [false]);
    expect(backend.speakerPreferences, [false]);

    await controller.handleSystemAudioActivation(true);
    expect(backend.engineAvailability, [false, true]);

    await controller.handleInterruption(true);
    expect(controller.interrupted, isTrue);
    expect(backend.engineAvailability, [false, true, false]);

    await controller.handleInterruption(false);
    expect(controller.interrupted, isFalse);
    expect(
      backend.engineAvailability,
      [false, true, false],
      reason: 'CallKit didActivate, not interruption end, owns reactivation',
    );
  });

  test('speaker preference is real backend state and route changes stay observable', () async {
    final backend = _FakeCallAudioBackend();
    final controller = CallAudioSessionController(backend: backend);

    await controller.prepare(video: true, externalCallSystem: false);
    expect(controller.speakerPreferred, isTrue);

    await controller.toggleSpeaker();
    expect(controller.speakerPreferred, isFalse);
    expect(backend.speakerPreferences, [true, false]);

    controller.updateRoute(
      const CallAudioRouteState(
        kind: CallAudioRouteKind.bluetooth,
        label: 'AirPods',
      ),
    );
    expect(controller.route.kind, CallAudioRouteKind.bluetooth);
    expect(controller.route.label, 'AirPods');
  });

  test('ending CallKit-managed audio restores LiveKit automatic management', () async {
    final backend = _FakeCallAudioBackend();
    final controller = CallAudioSessionController(backend: backend);

    await controller.prepare(video: true, externalCallSystem: true);
    await controller.handleSystemAudioActivation(true);
    await controller.release();

    expect(controller.externalCallSystem, isFalse);
    expect(backend.engineAvailability.last, isTrue);
    expect(backend.managementModes.last, CallAudioManagementMode.automatic);
  });
}

final class _FakeCallAudioBackend implements CallAudioBackend {
  final List<CallAudioManagementMode> managementModes = [];
  final List<bool> engineAvailability = [];
  final List<bool> speakerPreferences = [];

  @override
  Future<void> setEngineAvailable(bool available) async {
    engineAvailability.add(available);
  }

  @override
  Future<void> setManagementMode(CallAudioManagementMode mode) async {
    managementModes.add(mode);
  }

  @override
  Future<void> setSpeakerPreferred(bool preferred) async {
    speakerPreferences.add(preferred);
  }
}
