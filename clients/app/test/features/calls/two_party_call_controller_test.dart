import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/data/call_platform_service.dart';
import 'package:im_client/features/calls/data/call_signaling_client.dart';
import 'package:im_client/features/calls/data/http_call_session_api.dart';
import 'package:im_client/features/calls/domain/call_media_gateway.dart';
import 'package:im_client/features/calls/domain/call_session.dart';
import 'package:im_client/features/calls/domain/call_token.dart';
import 'package:im_client/features/calls/presentation/call_debug_controller.dart';
import 'package:im_client/features/calls/presentation/two_party_call_controller.dart';
import 'package:im_client/features/calls/presentation/two_party_call_page.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  testWidgets('incoming call does not overflow on a short Android viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final mediaController = CallDebugController();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: TwoPartyCallPage(
          mediaController: mediaController,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('接听'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    mediaController.dispose();
    await tester.pump();
  });

  test('empty peer identity reports a specific validation error', () async {
    final controller = TwoPartyCallController(
      _FakeCallMedia(),
      api: _FakeCallSessionApi(),
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        return _FakeSignalingClient();
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'alice',
      participantName: 'Alice',
    );
    await controller.placeCall(calleeIdentity: '   ', kind: CallKind.audio);

    expect(controller.errorMessage, '请输入对方身份。');
  });

  test('shutdown closes signaling without hanging', () async {
    final controller = TwoPartyCallController(
      _FakeCallMedia(),
      api: _FakeCallSessionApi(),
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        return _FakeSignalingClient();
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'alice',
      participantName: 'Alice',
    );
    await controller.shutdown().timeout(const Duration(seconds: 2));
  });

  test('calling self reports a specific validation error', () async {
    final controller = TwoPartyCallController(
      _FakeCallMedia(),
      api: _FakeCallSessionApi(),
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        return _FakeSignalingClient();
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'alice',
      participantName: 'Alice',
    );
    await controller.placeCall(calleeIdentity: 'alice', kind: CallKind.audio);

    expect(controller.errorMessage, '不能呼叫自己。');
  });

  test('caller creates an outgoing video call', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    expect(
      await controller.start(
        apiBaseUrl: 'http://127.0.0.1:18473',
        participantIdentity: 'alice',
        participantName: 'Alice',
      ),
      isTrue,
    );
    expect(controller.signalingConnected, isTrue);

    await controller.placeCall(calleeIdentity: 'bob', kind: CallKind.video);

    expect(controller.currentCall?.status, CallSessionStatus.ringing);
    expect(controller.isOutgoing, isTrue);
    expect(controller.peerIdentity, 'bob');
    expect(api.lastCreatedKind, CallKind.video);
    expect(signaling.disposed, isFalse);
  });

  test('outgoing CallKit audio is prepared before the system transaction starts', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform();
    platform.isAudioPrepared = () => media.systemCallManaged;
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'alice',
      participantName: 'Alice',
    );
    await controller.placeCall(calleeIdentity: 'bob', kind: CallKind.audio);

    expect(signaling.disposed, isFalse);
    expect(platform.outgoingReports, 1);
    expect(platform.audioPreparedWhenOutgoingStarted, isTrue);
    expect(controller.systemCallManaged, isTrue);
  });

  test('incoming ringing system decline maps to reject and acks success', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.decline,
      callId: 'abc123',
      actionId: 'incoming-decline-1',
    ));
    await pumpEventQueue();

    expect(api.appliedActions.last, 'reject');
    expect(platform.completions.last, (actionId: 'incoming-decline-1', success: true));
  });

  test('outgoing ringing system cancel maps to hangup and acks success', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform();
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) =>
          _FakeSignalingClient(),
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'alice',
      participantName: 'Alice',
    );
    await controller.placeCall(calleeIdentity: 'bob', kind: CallKind.audio);

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.cancel,
      callId: 'abc123',
      actionId: 'outgoing-cancel-1',
    ));
    await pumpEventQueue();

    expect(api.appliedActions.last, 'hangup');
    expect(platform.completions.last, (actionId: 'outgoing-cancel-1', success: true));
  });

  test('accepted incoming system end maps to hangup', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform()
      ..isSystemCallManaged = () => media.systemCallManaged;
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();
    signaling.emitCall('call.updated', api.acceptedCall.toJson());
    await pumpEventQueue();

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.end,
      callId: 'abc123',
      actionId: 'incoming-end-1',
    ));
    await pumpEventQueue();

    expect(api.appliedActions.last, 'hangup');
    expect(platform.completions.last, (actionId: 'incoming-end-1', success: true));
    expect(platform.systemManagedWhenCompleting, isTrue);
    expect(platform.endedReports, 0);
    expect(controller.systemCallManaged, isFalse);
  });

  test('accepted outgoing system end maps to hangup', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform()
      ..isSystemCallManaged = () => media.systemCallManaged;
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'alice',
      participantName: 'Alice',
    );
    await controller.placeCall(calleeIdentity: 'bob', kind: CallKind.audio);
    signaling.emitCall('call.updated', api.acceptedCall.toJson());
    await pumpEventQueue();

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.end,
      callId: 'abc123',
      actionId: 'outgoing-end-1',
    ));
    await pumpEventQueue();

    expect(api.appliedActions.last, 'hangup');
    expect(platform.completions.last, (actionId: 'outgoing-end-1', success: true));
    expect(platform.systemManagedWhenCompleting, isTrue);
    expect(platform.endedReports, 0);
    expect(controller.systemCallManaged, isFalse);
  });

  test('system answer server failure acks native failure and keeps ringing call', () async {
    final api = _FakeCallSessionApi()..failAction = 'accept';
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.accept,
      callId: 'abc123',
      actionId: 'answer-fail-1',
    ));
    await pumpEventQueue();

    expect(controller.currentCall?.status, CallSessionStatus.ringing);
    expect(platform.completions.last, (actionId: 'answer-fail-1', success: false));
  });

  test('system end server failure acks native failure and retains active call', () async {
    final api = _FakeCallSessionApi()..failAction = 'hangup';
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();
    signaling.emitCall('call.updated', api.acceptedCall.toJson());
    await pumpEventQueue();

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.end,
      callId: 'abc123',
      actionId: 'end-fail-1',
    ));
    await pumpEventQueue();

    expect(controller.currentCall?.status, CallSessionStatus.accepted);
    expect(controller.systemCallManaged, isTrue);
    expect(platform.completions.last, (actionId: 'end-fail-1', success: false));
  });

  test('ended server state converges CallKit when native action already timed out', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform()..completionResult = false;
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();
    signaling.emitCall('call.updated', api.acceptedCall.toJson());
    await pumpEventQueue();

    platform.emit(const CallPlatformEvent(
      type: CallPlatformEventType.end,
      callId: 'abc123',
      actionId: 'timed-out-end-1',
    ));
    await pumpEventQueue();

    expect(platform.completions.last, (actionId: 'timed-out-end-1', success: true));
    expect(platform.endedReports, 1);
    expect(controller.currentCall?.status, CallSessionStatus.ended);
    expect(controller.systemCallManaged, isFalse);
  });

  test('reconnect recovers a missed accepted call', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    expect(api.fetchActiveCount, 1);

    api.activeCall = api.acceptedCall;
    signaling.emitState(RealtimeConnectionState.disconnected);
    signaling.emitState(RealtimeConnectionState.connected);
    await pumpEventQueue();

    expect(api.fetchActiveCount, 2);
    expect(controller.currentCall?.status, CallSessionStatus.accepted);
    expect(media.connected, isTrue);
    expect(media.joinCount, 1);
  });

  test('iOS CallKit actions stay synchronized with DD call state', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    final platform = _FakeCallPlatform();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      platformGateway: platform,
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();

    expect(platform.incomingReports, 1);
    expect(controller.systemCallManaged, isTrue);
    expect(media.systemCallManaged, isTrue);

    await controller.accept();
    await pumpEventQueue();
    expect(platform.answerRequests, 1);
    expect(controller.currentCall?.status, CallSessionStatus.accepted);
    expect(platform.connectedReports, 1);
    expect(platform.completions.last, (actionId: 'answer-1', success: true));
    expect(media.joinCount, 1);

    platform.emit(const CallPlatformEvent(type: CallPlatformEventType.audioActivated));
    await pumpEventQueue();
    expect(media.lastSystemAudioActive, isTrue);

    platform.emit(const CallPlatformEvent(type: CallPlatformEventType.interruptionBegan));
    await pumpEventQueue();
    expect(media.lastSystemAudioInterrupted, isTrue);

    final ended = api.acceptedCall.copyWith(
      status: CallSessionStatus.ended,
      endedAt: DateTime.utc(2026, 8, 7, 1, 2),
      endReason: 'hangup',
    );
    signaling.emitCall('call.updated', ended.toJson());
    await pumpEventQueue();

    expect(platform.endedReports, 1);
    expect(controller.systemCallManaged, isFalse);
    expect(media.systemCallManaged, isFalse);
  });

  test('accepted call recovers media after an unexpected disconnect', () async {
    final api = _FakeCallSessionApi();
    final media = _FakeCallMedia();
    late _FakeSignalingClient signaling;
    final controller = TwoPartyCallController(
      media,
      api: api,
      mediaRecoveryDelays: const <Duration>[Duration.zero],
      signalingFactory: ({required apiBaseUri, required participantIdentity}) {
        signaling = _FakeSignalingClient();
        return signaling;
      },
    );
    addTearDown(controller.dispose);

    await controller.start(
      apiBaseUrl: 'http://127.0.0.1:18473',
      participantIdentity: 'bob',
      participantName: 'Bob',
    );
    signaling.emitCall('call.incoming', api.ringingCall.toJson());
    await pumpEventQueue();
    await controller.accept();
    expect(media.joinCount, 1);

    media.emitUnexpectedDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(media.connected, isTrue);
    expect(media.joinCount, 2);
    expect(controller.currentCall?.status, CallSessionStatus.accepted);
  });

  test(
    'callee receives, accepts, joins media, and leaves on remote hangup',
    () async {
      final api = _FakeCallSessionApi();
      final media = _FakeCallMedia();
      late _FakeSignalingClient signaling;
      final controller = TwoPartyCallController(
        media,
        api: api,
        signalingFactory:
            ({required apiBaseUri, required participantIdentity}) {
              signaling = _FakeSignalingClient();
              return signaling;
            },
      );
      addTearDown(controller.dispose);

      await controller.start(
        apiBaseUrl: 'http://127.0.0.1:18473',
        participantIdentity: 'bob',
        participantName: 'Bob',
      );

      signaling.emitCall('call.incoming', api.ringingCall.toJson());
      await pumpEventQueue();
      expect(controller.isIncoming, isTrue);

      await controller.accept();
      expect(controller.currentCall?.status, CallSessionStatus.accepted);
      expect(media.joinCount, 1);
      expect(media.cameraEnabled, isTrue);
      expect(media.connected, isTrue);

      final ended = api.acceptedCall.copyWith(
        status: CallSessionStatus.ended,
        endedAt: DateTime.utc(2026, 8, 7, 1, 2),
        endReason: 'hangup',
      );
      signaling.emitCall('call.updated', ended.toJson());
      await pumpEventQueue();

      expect(controller.currentCall?.status, CallSessionStatus.ended);
      expect(media.connected, isFalse);
      expect(media.leaveCount, 1);
    },
  );
}

final class _FakeCallSessionApi implements CallSessionApi {
  final DateTime now = DateTime.utc(2026, 8, 7);
  CallKind? lastCreatedKind;
  CallSession? activeCall;
  int fetchActiveCount = 0;
  String? failAction;
  final List<String> appliedActions = <String>[];

  late final CallSession ringingCall = CallSession(
    id: 'abc123',
    roomName: 'call-abc123',
    callerIdentity: 'alice',
    callerName: 'Alice',
    calleeIdentity: 'bob',
    kind: CallKind.video,
    status: CallSessionStatus.ringing,
    createdAt: now,
    acceptedAt: null,
    endedAt: null,
    endReason: '',
  );

  late final CallSession acceptedCall = ringingCall.copyWith(
    status: CallSessionStatus.accepted,
    acceptedAt: now.add(const Duration(seconds: 2)),
  );

  @override
  Future<CallSession> createCall({
    required Uri apiBaseUri,
    required String callerIdentity,
    required String callerName,
    required String calleeIdentity,
    required CallKind kind,
  }) async {
    lastCreatedKind = kind;
    return CallSession(
      id: ringingCall.id,
      roomName: ringingCall.roomName,
      callerIdentity: callerIdentity,
      callerName: callerName,
      calleeIdentity: calleeIdentity,
      kind: kind,
      status: CallSessionStatus.ringing,
      createdAt: now,
      acceptedAt: null,
      endedAt: null,
      endReason: '',
    );
  }

  @override
  Future<CallSession?> fetchActiveCall({
    required Uri apiBaseUri,
    required String participantIdentity,
  }) async {
    fetchActiveCount++;
    return activeCall;
  }

  @override
  Future<CallSession> applyAction({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String action,
  }) async {
    appliedActions.add(action);
    if (failAction == action) {
      throw const CallApiException(
        code: 'TEST_FAILURE',
        message: 'simulated system action failure',
      );
    }
    if (action == 'accept') return acceptedCall;
    if (action == 'reject') {
      return ringingCall.copyWith(
        status: CallSessionStatus.rejected,
        endedAt: now.add(const Duration(seconds: 4)),
        endReason: 'rejected',
      );
    }
    return acceptedCall.copyWith(
      status: CallSessionStatus.ended,
      endedAt: now.add(const Duration(seconds: 4)),
      endReason: 'hangup',
    );
  }

  @override
  Future<CallToken> issueToken({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String participantName,
  }) async {
    return CallToken(
      serverUrl: Uri.parse('ws://127.0.0.1:7880'),
      participantToken: 'token',
      expiresAt: now.add(const Duration(minutes: 10)),
    );
  }

  @override
  void close() {}
}

final class _FakeSignalingClient implements CallSignalingClient {
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast(sync: true);
  final StreamController<RealtimeConnectionState> _states =
      StreamController<RealtimeConnectionState>.broadcast(sync: true);
  final StreamController<Object> _errors = StreamController<Object>.broadcast(
    sync: true,
  );

  bool disposed = false;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  Stream<RealtimeConnectionState> get states => _states.stream;

  @override
  Future<void> connect() async {
    _states.add(RealtimeConnectionState.connected);
  }

  void emitState(RealtimeConnectionState state) {
    _states.add(state);
  }

  void emitCall(String type, Map<String, dynamic> payload) {
    _events.add(
      RealtimeEvent(
        type: type,
        requestId: '',
        eventId: 1,
        payload: payload,
        error: null,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
    await _states.close();
    await _errors.close();
  }
}

final class _FakeCallPlatform implements CallPlatformGateway {
  final StreamController<CallPlatformEvent> _events =
      StreamController<CallPlatformEvent>.broadcast(sync: true);

  int incomingReports = 0;
  int outgoingReports = 0;
  int answerRequests = 0;
  int endRequests = 0;
  int connectedReports = 0;
  int endedReports = 0;
  final List<({String actionId, bool success})> completions = [];
  bool completionResult = true;
  bool Function()? isAudioPrepared;
  bool Function()? isSystemCallManaged;
  bool? audioPreparedWhenOutgoingStarted;
  bool? systemManagedWhenCompleting;

  @override
  bool get isIOS => true;

  @override
  Stream<CallPlatformEvent> get events => _events.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<CallMediaPermissionResult> requestMediaPermissions({
    required bool microphone,
    required bool camera,
  }) async => CallMediaPermissionResult.unavailable;

  @override
  Future<bool> reportIncomingCall({
    required String callId,
    required String callerName,
    required bool video,
  }) async {
    incomingReports++;
    return true;
  }

  @override
  Future<bool> startOutgoingCall({
    required String callId,
    required String peerName,
    required bool video,
  }) async {
    outgoingReports++;
    audioPreparedWhenOutgoingStarted = isAudioPrepared?.call();
    return true;
  }

  @override
  Future<bool> answerCall(String callId) async {
    answerRequests++;
    emit(CallPlatformEvent(
      type: CallPlatformEventType.accept,
      callId: callId,
      actionId: 'answer-$answerRequests',
    ));
    return true;
  }

  @override
  Future<bool> endCall(String callId) async {
    endRequests++;
    emit(CallPlatformEvent(
      type: CallPlatformEventType.end,
      callId: callId,
      actionId: 'end-$endRequests',
    ));
    return true;
  }

  @override
  Future<bool> completeSystemAction({
    required String actionId,
    required bool success,
  }) async {
    completions.add((actionId: actionId, success: success));
    systemManagedWhenCompleting = isSystemCallManaged?.call();
    return completionResult;
  }

  @override
  Future<void> reportConnected(String callId) async {
    connectedReports++;
  }

  @override
  Future<void> reportEnded(String callId) async {
    endedReports++;
  }

  void emit(CallPlatformEvent event) => _events.add(event);
}

final class _FakeCallMedia implements CallMediaGateway {
  final StreamController<CallMediaConnectionEvent> _connectionEvents =
      StreamController<CallMediaConnectionEvent>.broadcast(sync: true);

  @override
  bool connected = false;
  @override
  bool microphoneEnabled = false;
  @override
  bool cameraEnabled = false;
  @override
  bool speakerPreferred = false;
  @override
  String audioRouteLabel = '系统音频';
  @override
  String? lastError;
  @override
  Stream<CallMediaConnectionEvent> get connectionEvents =>
      _connectionEvents.stream;

  int joinCount = 0;
  int leaveCount = 0;
  bool systemCallManaged = false;
  bool? lastSystemAudioActive;
  bool? lastSystemAudioInterrupted;

  @override
  Future<bool> joinWithCredentials({
    required CallToken credentials,
    required String roomName,
    required bool enableMicrophone,
    required bool enableCamera,
  }) async {
    joinCount++;
    connected = true;
    microphoneEnabled = enableMicrophone;
    cameraEnabled = enableCamera;
    _connectionEvents.add(
      const CallMediaConnectionEvent(state: CallMediaConnectionState.connected),
    );
    return true;
  }

  @override
  Future<void> leave() async {
    leaveCount++;
    connected = false;
    microphoneEnabled = false;
    cameraEnabled = false;
    _connectionEvents.add(
      const CallMediaConnectionEvent(state: CallMediaConnectionState.disconnected),
    );
  }

  void emitUnexpectedDisconnect() {
    connected = false;
    microphoneEnabled = false;
    cameraEnabled = false;
    _connectionEvents.add(
      const CallMediaConnectionEvent(
        state: CallMediaConnectionState.disconnected,
        unexpected: true,
      ),
    );
  }

  @override
  Future<void> setCameraSuspended(bool suspended) async {}

  @override
  Future<void> setSystemAudioActive(bool active) async {
    lastSystemAudioActive = active;
  }

  @override
  Future<void> setSystemAudioInterrupted(bool interrupted) async {
    lastSystemAudioInterrupted = interrupted;
  }

  @override
  Future<bool> setSystemCallManaged(bool managed, {required bool video}) async {
    systemCallManaged = managed;
    return true;
  }

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> toggleCamera() async {
    cameraEnabled = !cameraEnabled;
  }

  @override
  Future<void> toggleMicrophone() async {
    microphoneEnabled = !microphoneEnabled;
  }

  @override
  Future<void> toggleSpeaker() async {
    speakerPreferred = !speakerPreferred;
  }
}

extension on CallSession {
  CallSession copyWith({
    CallSessionStatus? status,
    DateTime? acceptedAt,
    DateTime? endedAt,
    String? endReason,
  }) {
    return CallSession(
      id: id,
      roomName: roomName,
      callerIdentity: callerIdentity,
      callerName: callerName,
      calleeIdentity: calleeIdentity,
      kind: kind,
      status: status ?? this.status,
      createdAt: createdAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      endedAt: endedAt ?? this.endedAt,
      endReason: endReason ?? this.endReason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'room_name': roomName,
      'caller_identity': callerIdentity,
      'caller_name': callerName,
      'callee_identity': calleeIdentity,
      'kind': kind.name,
      'status': status.name,
      'created_at': createdAt.toIso8601String(),
      if (acceptedAt != null) 'accepted_at': acceptedAt!.toIso8601String(),
      if (endedAt != null) 'ended_at': endedAt!.toIso8601String(),
      if (endReason.isNotEmpty) 'end_reason': endReason,
    };
  }
}
