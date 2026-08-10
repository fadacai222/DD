import 'package:realtime_poc/realtime_poc.dart';

abstract interface class CallSignalingClient {
  Stream<RealtimeEvent> get events;
  Stream<RealtimeConnectionState> get states;
  Stream<Object> get errors;

  Future<void> connect();
  Future<void> dispose();
}

final class RealtimeCallSignalingClient implements CallSignalingClient {
  RealtimeCallSignalingClient({
    required Uri apiBaseUri,
    required String participantIdentity,
    String? accessToken,
  }) : _client = RealtimeClient(
         baseUri: apiBaseUri,
         clientId: participantIdentity,
         webSocketPath: '/api/v1/realtime',
         accessToken: accessToken,
         protocolVersion: '1',
       );

  final RealtimeClient _client;

  @override
  Stream<RealtimeEvent> get events => _client.events;

  @override
  Stream<RealtimeConnectionState> get states => _client.states;

  @override
  Stream<Object> get errors => _client.errors;

  @override
  Future<void> connect() => _client.connect();

  Future<void> updateAccessToken(String accessToken) =>
      _client.updateAccessToken(accessToken);

  @override
  Future<void> dispose() => _client.dispose();
}

typedef CallSignalingFactory =
    CallSignalingClient Function({
      required Uri apiBaseUri,
      required String participantIdentity,
    });
