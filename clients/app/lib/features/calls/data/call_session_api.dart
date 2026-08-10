import '../domain/call_session.dart';
import '../domain/call_token.dart';

abstract interface class CallSessionApi {
  Future<CallSession> createCall({
    required Uri apiBaseUri,
    required String callerIdentity,
    required String callerName,
    required String calleeIdentity,
    required CallKind kind,
  });

  Future<CallSession?> fetchActiveCall({
    required Uri apiBaseUri,
    required String participantIdentity,
  });

  Future<CallSession> applyAction({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String action,
  });

  Future<CallToken> issueToken({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String participantName,
  });

  void close();
}
