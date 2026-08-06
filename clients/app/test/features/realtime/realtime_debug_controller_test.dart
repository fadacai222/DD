import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/realtime/domain/debug_log_entry.dart';
import 'package:im_client/features/realtime/presentation/realtime_debug_controller.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../support/fake_realtime_gateway.dart';

void main() {
  group('RealtimeDebugController', () {
    test('rejects unsafe or malformed server URLs', () async {
      var factoryCalls = 0;
      final controller = RealtimeDebugController(
        gatewayFactory: (baseUri, clientId) {
          factoryCalls++;
          return FakeRealtimeGateway();
        },
        clientId: 'test-client',
      );
      addTearDown(controller.dispose);

      final result = await controller.checkHealth(
        'http://user:password@127.0.0.1:18473/private?token=x',
      );

      expect(result, isFalse);
      expect(factoryCalls, 0);
      expect(controller.logs, hasLength(1));
      expect(controller.logs.single.level, DebugLogLevel.error);
    });

    test('checks health without retaining a realtime connection', () async {
      final gateway = FakeRealtimeGateway();
      final controller = RealtimeDebugController(
        gatewayFactory: (baseUri, clientId) => gateway,
        clientId: 'test-client',
      );
      addTearDown(controller.dispose);

      final result = await controller.checkHealth('http://127.0.0.1:18473/');

      expect(result, isTrue);
      expect(controller.healthSummary, 'fake-realtime · ok');
      expect(gateway.disposeCalls, 1);
      expect(controller.connectionState, RealtimeConnectionState.disconnected);
    });

    test('connects, records events, sends ping, and disconnects', () async {
      final gateway = FakeRealtimeGateway();
      final controller = RealtimeDebugController(
        gatewayFactory: (baseUri, clientId) => gateway,
        clientId: 'test-client',
      );
      addTearDown(controller.dispose);

      final connected = await controller.connect('http://127.0.0.1:18473');
      gateway.emitEvent(
        const RealtimeEvent(
          type: 'hello_ack',
          requestId: 'request-1',
          eventId: 1,
          payload: <String, dynamic>{'protocolVersion': '1'},
          error: null,
        ),
      );

      expect(connected, isTrue);
      expect(controller.isConnected, isTrue);
      expect(controller.activeServer?.origin, 'http://127.0.0.1:18473');
      expect(controller.sendPing(), isTrue);
      expect(gateway.pingCalls, 1);
      expect(
        controller.logs.any((entry) => entry.message.contains('hello_ack')),
        isTrue,
      );

      await controller.disconnect();

      expect(gateway.disconnectCalls, 1);
      expect(gateway.disposeCalls, 1);
      expect(controller.isConnected, isFalse);
    });

    test('keeps only the newest 200 log entries', () async {
      final gateway = FakeRealtimeGateway();
      final controller = RealtimeDebugController(
        gatewayFactory: (baseUri, clientId) => gateway,
        clientId: 'test-client',
      );
      addTearDown(controller.dispose);

      await controller.connect('http://127.0.0.1:18473');
      for (var eventId = 1; eventId <= 230; eventId++) {
        gateway.emitEvent(
          RealtimeEvent(
            type: 'test_event',
            requestId: '',
            eventId: eventId,
            payload: <String, dynamic>{'value': eventId},
            error: null,
          ),
        );
      }

      expect(controller.logs, hasLength(RealtimeDebugController.maxLogEntries));
      expect(controller.logs.last.message, contains('#230'));
      expect(controller.logs.first.message, isNot(contains('#1 ')));
    });
  });
}
