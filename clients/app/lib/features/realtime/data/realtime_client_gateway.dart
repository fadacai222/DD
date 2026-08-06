import 'package:realtime_poc/realtime_poc.dart';

import '../domain/realtime_gateway.dart';

final class RealtimeClientGateway implements RealtimeGateway {
  RealtimeClientGateway({required Uri baseUri, required String clientId})
    : _client = RealtimeClient(baseUri: baseUri, clientId: clientId);

  final RealtimeClient _client;

  @override
  Stream<Object> get errors => _client.errors;

  @override
  Stream<RealtimeEvent> get events => _client.events;

  @override
  Stream<RealtimeConnectionState> get states => _client.states;

  @override
  Future<void> connect() => _client.connect();

  @override
  Future<void> disconnect() => _client.disconnect();

  @override
  Future<void> dispose() => _client.dispose();

  @override
  Future<Map<String, dynamic>> fetchHealth() => _client.fetchHealth();

  @override
  void sendPing() => _client.sendPing();
}
