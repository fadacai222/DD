import 'package:realtime_poc/realtime_poc.dart';

abstract interface class RealtimeGateway {
  Stream<RealtimeEvent> get events;

  Stream<RealtimeConnectionState> get states;

  Stream<Object> get errors;

  Future<Map<String, dynamic>> fetchHealth();

  Future<void> connect();

  Future<void> disconnect();

  void sendPing();

  Future<void> dispose();
}

typedef RealtimeGatewayFactory =
    RealtimeGateway Function(Uri baseUri, String clientId);
