import 'call_token.dart';

enum CallMediaConnectionState { disconnected, connecting, connected, reconnecting }

final class CallMediaConnectionEvent {
  const CallMediaConnectionEvent({
    required this.state,
    this.unexpected = false,
  });

  final CallMediaConnectionState state;
  final bool unexpected;
}

abstract interface class CallMediaGateway {
  bool get connected;
  bool get microphoneEnabled;
  bool get cameraEnabled;
  bool get speakerPreferred;
  String get audioRouteLabel;
  String? get lastError;
  Stream<CallMediaConnectionEvent> get connectionEvents;

  Future<bool> joinWithCredentials({
    required CallToken credentials,
    required String roomName,
    required bool enableMicrophone,
    required bool enableCamera,
  });

  Future<void> leave();
  Future<void> toggleMicrophone();
  Future<void> toggleCamera();
  Future<void> switchCamera();
  Future<void> toggleSpeaker();
  Future<void> setCameraSuspended(bool suspended);
  Future<bool> setSystemCallManaged(bool managed, {required bool video});
  Future<void> setSystemAudioActive(bool active);
  Future<void> setSystemAudioInterrupted(bool interrupted);
}
