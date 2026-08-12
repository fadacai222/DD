import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/data/call_audio_session_controller.dart';
import 'package:im_client/features/calls/data/call_platform_service.dart';

void main() {
  test('permission result treats denied microphone and camera explicitly', () {
    final permissions = CallMediaPermissionResult.fromMap(const {
      'microphone': 'denied',
      'camera': 'granted',
    });

    expect(permissions.microphone, CallMediaPermission.denied);
    expect(permissions.camera, CallMediaPermission.granted);
    expect(permissions.allGranted(microphone: true, camera: true), isFalse);
    expect(permissions.allGranted(microphone: false, camera: true), isTrue);
  });

  test('route event preserves Bluetooth route instead of a speaker bool', () {
    final event = CallPlatformEvent.fromMap(const {
      'type': 'routeChanged',
      'routeKind': 'bluetooth',
      'routeLabel': 'AirPods Pro',
    });

    expect(event.type, CallPlatformEventType.routeChanged);
    expect(event.route?.kind, CallAudioRouteKind.bluetooth);
    expect(event.route?.label, 'AirPods Pro');
  });

  test('system call actions preserve call id for server state synchronization', () {
    for (final type in ['accept', 'decline', 'end']) {
      final event = CallPlatformEvent.fromMap({
        'type': type,
        'callId': 'call-42',
      });
      expect(event.callId, 'call-42');
    }
  });
}
