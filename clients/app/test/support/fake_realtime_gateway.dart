import 'dart:async';

import 'package:im_client/features/realtime/domain/realtime_gateway.dart';
import 'package:realtime_poc/realtime_poc.dart';

final class FakeRealtimeGateway implements RealtimeGateway {
  FakeRealtimeGateway({
    this.healthResponse = const <String, dynamic>{
      'status': 'ok',
      'service': 'fake-realtime',
    },
    this.connectError,
  });

  final Map<String, dynamic> healthResponse;
  final Object? connectError;

  final StreamController<RealtimeConnectionState> _states =
      StreamController<RealtimeConnectionState>.broadcast(sync: true);
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast(sync: true);
  final StreamController<Object> _errors = StreamController<Object>.broadcast(
    sync: true,
  );

  int connectCalls = 0;
  int disconnectCalls = 0;
  int pingCalls = 0;
  int disposeCalls = 0;
  bool _disposed = false;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  Stream<RealtimeConnectionState> get states => _states.stream;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (connectError case final error?) {
      throw error;
    }
    _states
      ..add(RealtimeConnectionState.connecting)
      ..add(RealtimeConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    if (!_disposed) {
      _states.add(RealtimeConnectionState.disconnected);
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (_disposed) {
      return;
    }
    _disposed = true;
    await Future.wait<void>([
      _states.close(),
      _events.close(),
      _errors.close(),
    ]);
  }

  @override
  Future<Map<String, dynamic>> fetchHealth() async => healthResponse;

  @override
  void sendPing() {
    pingCalls++;
  }

  void emitEvent(RealtimeEvent event) {
    if (!_disposed) {
      _events.add(event);
    }
  }

  void emitError(Object error) {
    if (!_disposed) {
      _errors.add(error);
    }
  }
}
