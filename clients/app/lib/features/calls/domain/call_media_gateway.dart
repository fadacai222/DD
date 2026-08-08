import 'call_token.dart';

abstract interface class CallMediaGateway {
  bool get connected;
  bool get microphoneEnabled;
  bool get cameraEnabled;
  String? get lastError;

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
}
