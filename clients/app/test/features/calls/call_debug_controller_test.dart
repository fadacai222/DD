import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/data/call_platform_service.dart';
import 'package:im_client/features/calls/domain/call_log_entry.dart';
import 'package:im_client/features/calls/domain/call_token.dart';
import 'package:im_client/features/calls/presentation/call_debug_controller.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../support/fake_call_token_provider.dart';

void main() {
  test('rejects malformed call settings before requesting a token', () async {
    final tokenProvider = FakeCallTokenProvider();
    final controller = CallDebugController(tokenProvider: tokenProvider);
    addTearDown(controller.dispose);

    final result = await controller.join(
      tokenApiBaseUrl: 'file:///tmp/server',
      roomName: '../bad-room',
      participantIdentity: 'bad identity',
      participantName: '',
      enableMicrophone: false,
      enableCamera: false,
    );

    expect(result, isFalse);
    expect(tokenProvider.issueCalls, 0);
    expect(controller.connected, isFalse);
    expect(controller.logs, hasLength(1));
    expect(controller.logs.single.level, CallLogLevel.error);
  });

  test('iOS microphone denial fails before creating LiveKit media', () async {
    final platform = _FakeCallPlatform(
      permissions: const CallMediaPermissionResult(
        microphone: CallMediaPermission.denied,
        camera: CallMediaPermission.notRequested,
      ),
    );
    final controller = CallDebugController(platformGateway: platform);
    addTearDown(controller.dispose);

    final joined = await controller.joinWithCredentials(
      credentials: CallToken(
        serverUrl: Uri.parse('wss://livekit.example.test'),
        participantToken: 'token',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      roomName: 'call-permission-test',
      enableMicrophone: true,
      enableCamera: false,
    );

    expect(joined, isFalse);
    expect(platform.permissionRequests, 1);
    expect(controller.lastError, contains('麦克风权限'));
    expect(controller.connected, isFalse);
  });

  test('connectivity diagnostics requires TURN to succeed', () async {
    final tokenProvider = FakeCallTokenProvider();
    final controller = CallDebugController(
      tokenProvider: tokenProvider,
      connectivityCheckRunner: (_) async => const [
        CheckInfo(
          name: 'WebSocketCheck',
          description: 'Can connect via WebSocket',
          status: CheckStatus.success,
          logs: [],
        ),
        CheckInfo(
          name: 'WebRTCCheck',
          description: 'Can connect via WebRTC',
          status: CheckStatus.success,
          logs: [],
        ),
        CheckInfo(
          name: 'TURNCheck',
          description: 'Can connect via TURN',
          status: CheckStatus.failed,
          logs: [
            CheckLog(level: CheckLogLevel.error, message: 'TURN relay failed'),
          ],
        ),
      ],
    );
    addTearDown(controller.dispose);

    final result = await controller.runConnectivityDiagnostics(
      tokenApiBaseUrl: 'http://127.0.0.1:18473',
      roomName: 'diag-room',
      participantIdentity: 'diag-user',
      participantName: 'Diag User',
    );

    expect(result, isFalse);
    expect(tokenProvider.issueCalls, 1);
    expect(
      controller.logs.any(
        (entry) =>
            entry.message.contains('TURN') && entry.message.contains('失败'),
      ),
      isTrue,
    );
  });

  test('keeps at most 150 validation log entries', () async {
    final tokenProvider = FakeCallTokenProvider();
    final controller = CallDebugController(tokenProvider: tokenProvider);
    addTearDown(controller.dispose);

    for (var index = 0; index < 180; index++) {
      await controller.join(
        tokenApiBaseUrl: 'bad-url',
        roomName: 'call-demo',
        participantIdentity: 'user-$index',
        participantName: 'User',
        enableMicrophone: false,
        enableCamera: false,
      );
    }

    expect(controller.logs, hasLength(CallDebugController.maxLogEntries));
    expect(tokenProvider.issueCalls, 0);
  });
}

final class _FakeCallPlatform implements CallPlatformGateway {
  _FakeCallPlatform({required this.permissions});

  final CallMediaPermissionResult permissions;
  int permissionRequests = 0;

  @override
  bool get isIOS => true;

  @override
  Stream<CallPlatformEvent> get events => const Stream.empty();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<CallMediaPermissionResult> requestMediaPermissions({
    required bool microphone,
    required bool camera,
  }) async {
    permissionRequests++;
    return permissions;
  }

  @override
  Future<bool> answerCall(String callId) async => true;

  @override
  Future<bool> endCall(String callId) async => true;

  @override
  Future<bool> completeSystemAction({
    required String actionId,
    required bool success,
  }) async => true;

  @override
  Future<void> reportConnected(String callId) async {}

  @override
  Future<void> reportEnded(String callId) async {}

  @override
  Future<bool> reportIncomingCall({
    required String callId,
    required String callerName,
    required bool video,
  }) async => true;

  @override
  Future<bool> startOutgoingCall({
    required String callId,
    required String peerName,
    required bool video,
  }) async => true;
}
