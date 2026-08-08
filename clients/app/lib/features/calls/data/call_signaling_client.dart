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
  }) : _client = RealtimeClient(
         baseUri: apiBaseUri,
         clientId: participantIdentity,
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

  @override
  Future<void> dispose() => _client.dispose();
}

typedef CallSignalingFactory =
    CallSignalingClient Function({
      required Uri apiBaseUri,
      required String participantIdentity,
    });
