import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_audio_session_controller.dart';

enum CallMediaPermission { granted, denied, notRequested, unavailable }

final class CallMediaPermissionResult {
  const CallMediaPermissionResult({
    required this.microphone,
    required this.camera,
  });

  factory CallMediaPermissionResult.fromMap(Map<Object?, Object?> map) {
    CallMediaPermission parse(Object? raw) => switch (raw?.toString()) {
      'granted' => CallMediaPermission.granted,
      'denied' => CallMediaPermission.denied,
      'notRequested' => CallMediaPermission.notRequested,
      _ => CallMediaPermission.unavailable,
    };
    return CallMediaPermissionResult(
      microphone: parse(map['microphone']),
      camera: parse(map['camera']),
    );
  }

  static const unavailable = CallMediaPermissionResult(
    microphone: CallMediaPermission.unavailable,
    camera: CallMediaPermission.unavailable,
  );

  final CallMediaPermission microphone;
  final CallMediaPermission camera;

  bool allGranted({required bool microphone, required bool camera}) {
    bool allowed(CallMediaPermission state) =>
        state == CallMediaPermission.granted ||
        state == CallMediaPermission.notRequested ||
        state == CallMediaPermission.unavailable;
    return (!microphone || allowed(this.microphone)) &&
        (!camera || allowed(this.camera));
  }
}

enum CallPlatformEventType {
  accept,
  decline,
  cancel,
  end,
  audioActivated,
  audioDeactivated,
  interruptionBegan,
  interruptionEnded,
  routeChanged,
  unknown,
}

final class CallPlatformEvent {
  const CallPlatformEvent({
    required this.type,
    this.callId,
    this.actionId,
    this.route,
  });

  factory CallPlatformEvent.fromMap(Map<Object?, Object?> map) {
    final type = switch (map['type']?.toString()) {
      'accept' => CallPlatformEventType.accept,
      'decline' => CallPlatformEventType.decline,
      'cancel' => CallPlatformEventType.cancel,
      'end' => CallPlatformEventType.end,
      'audioActivated' => CallPlatformEventType.audioActivated,
      'audioDeactivated' => CallPlatformEventType.audioDeactivated,
      'interruptionBegan' => CallPlatformEventType.interruptionBegan,
      'interruptionEnded' => CallPlatformEventType.interruptionEnded,
      'routeChanged' => CallPlatformEventType.routeChanged,
      _ => CallPlatformEventType.unknown,
    };
    final routeKind = switch (map['routeKind']?.toString()) {
      'receiver' => CallAudioRouteKind.receiver,
      'speaker' => CallAudioRouteKind.speaker,
      'bluetooth' => CallAudioRouteKind.bluetooth,
      'headphones' => CallAudioRouteKind.headphones,
      'airPlay' => CallAudioRouteKind.airPlay,
      _ => CallAudioRouteKind.other,
    };
    final hasRoute = type == CallPlatformEventType.routeChanged ||
        map.containsKey('routeKind');
    return CallPlatformEvent(
      type: type,
      callId: map['callId']?.toString(),
      actionId: map['actionId']?.toString(),
      route: hasRoute
          ? CallAudioRouteState(
              kind: routeKind,
              label: map['routeLabel']?.toString().trim().isNotEmpty == true
                  ? map['routeLabel'].toString().trim()
                  : '系统音频',
            )
          : null,
    );
  }

  final CallPlatformEventType type;
  final String? callId;
  final String? actionId;
  final CallAudioRouteState? route;
}

abstract interface class CallPlatformGateway {
  bool get isIOS;
  Stream<CallPlatformEvent> get events;

  Future<bool> isAvailable();
  Future<CallMediaPermissionResult> requestMediaPermissions({
    required bool microphone,
    required bool camera,
  });
  Future<bool> reportIncomingCall({
    required String callId,
    required String callerName,
    required bool video,
  });
  Future<bool> startOutgoingCall({
    required String callId,
    required String peerName,
    required bool video,
  });
  Future<bool> answerCall(String callId);
  Future<bool> endCall(String callId);
  Future<bool> completeSystemAction({
    required String actionId,
    required bool success,
  });
  Future<void> reportConnected(String callId);
  Future<void> reportEnded(String callId);
}

final class CallPlatformService implements CallPlatformGateway {
  CallPlatformService({
    MethodChannel? channel,
    EventChannel? eventChannel,
    bool? isIOS,
  }) : _channel = channel ?? const MethodChannel(_methodChannelName),
       _eventChannel =
           eventChannel ?? const EventChannel(_eventChannelName),
       _isIOS =
           isIOS ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  static const _methodChannelName = 'org.openimx.client/call_platform';
  static const _eventChannelName = 'org.openimx.client/call_platform_events';
  static final CallPlatformService shared = CallPlatformService();

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final bool _isIOS;
  Stream<CallPlatformEvent>? _events;

  @override
  bool get isIOS => _isIOS;

  @override
  Stream<CallPlatformEvent> get events {
    if (!_isIOS) return const Stream<CallPlatformEvent>.empty();
    return _events ??= _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => CallPlatformEvent.fromMap(event as Map<Object?, Object?>))
        .handleError((Object _) {})
        .asBroadcastStream();
  }

  @override
  Future<bool> isAvailable() async {
    if (!_isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<CallMediaPermissionResult> requestMediaPermissions({
    required bool microphone,
    required bool camera,
  }) async {
    if (!_isIOS) return CallMediaPermissionResult.unavailable;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'requestMediaPermissions',
        <String, Object?>{
          'microphone': microphone,
          'camera': camera,
        },
      );
      return raw == null
          ? CallMediaPermissionResult.unavailable
          : CallMediaPermissionResult.fromMap(raw);
    } on MissingPluginException {
      // AI1 may not have linked the native service yet. LiveKit still performs
      // its normal permission request; absence of this preflight must not brick
      // foreground calls.
      return CallMediaPermissionResult.unavailable;
    } on PlatformException {
      return CallMediaPermissionResult.unavailable;
    }
  }

  @override
  Future<bool> reportIncomingCall({
    required String callId,
    required String callerName,
    required bool video,
  }) => _invokeBool('reportIncomingCall', <String, Object?>{
    'callId': callId,
    'callerName': callerName,
    'video': video,
  });

  @override
  Future<bool> startOutgoingCall({
    required String callId,
    required String peerName,
    required bool video,
  }) => _invokeBool('startOutgoingCall', <String, Object?>{
    'callId': callId,
    'peerName': peerName,
    'video': video,
  });

  @override
  Future<bool> answerCall(String callId) =>
      _invokeBool('answerCall', <String, Object?>{'callId': callId});

  @override
  Future<bool> endCall(String callId) =>
      _invokeBool('endCall', <String, Object?>{'callId': callId});

  @override
  Future<bool> completeSystemAction({
    required String actionId,
    required bool success,
  }) => _invokeBool('completeSystemAction', <String, Object?>{
    'actionId': actionId,
    'success': success,
  });

  @override
  Future<void> reportConnected(String callId) async {
    await _invokeBool('reportConnected', <String, Object?>{'callId': callId});
  }

  @override
  Future<void> reportEnded(String callId) async {
    await _invokeBool('reportEnded', <String, Object?>{'callId': callId});
  }

  Future<bool> _invokeBool(String method, Map<String, Object?> arguments) async {
    if (!_isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
