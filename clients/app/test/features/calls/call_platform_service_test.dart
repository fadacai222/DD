import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/data/call_audio_session_controller.dart';
import 'package:im_client/features/calls/data/call_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('system call actions preserve call and action ids for server synchronization', () {
    for (final type in ['accept', 'decline', 'cancel', 'end']) {
      final event = CallPlatformEvent.fromMap({
        'type': type,
        'callId': 'call-42',
        'actionId': 'action-$type',
      });
      expect(event.callId, 'call-42');
      expect(event.actionId, 'action-$type');
    }
    expect(
      CallPlatformEvent.fromMap(const {'type': 'cancel'}).type,
      CallPlatformEventType.cancel,
    );
  });

  test('system action completion forwards action id and success exactly once per call', () async {
    const channel = MethodChannel('test/dd/call-platform');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = CallPlatformService(
      channel: channel,
      eventChannel: const EventChannel('test/dd/call-platform-events'),
      isIOS: true,
    );

    expect(
      await service.completeSystemAction(
        actionId: '1f8a4df4-7577-4b33-b60b-2ee419490759',
        success: false,
      ),
      isTrue,
    );
    expect(calls, hasLength(1));
    expect(calls.single.method, 'completeSystemAction');
    expect(calls.single.arguments, <String, Object?>{
      'actionId': '1f8a4df4-7577-4b33-b60b-2ee419490759',
      'success': false,
    });
  });
}
