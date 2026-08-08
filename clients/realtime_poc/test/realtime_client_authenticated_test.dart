import 'dart:convert';
import 'dart:io';

import 'package:realtime_poc/realtime_poc.dart';
import 'package:test/test.dart';

void main() {
  test(
    'formal realtime path sends token and protocol version in hello',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Map<String, dynamic>? receivedHello;
      final sockets = <WebSocket>[];

      server.listen((request) async {
        if (request.uri.path != '/api/v1/realtime') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          if (raw is! String) return;
          final message = jsonDecode(raw) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          receivedHello = message;
          try {
            socket.add(
              jsonEncode({
                'type': 'hello_ack',
                'requestId': message['requestId'],
                'eventId': 1,
                'payload': {
                  'connectionId': 'formal-test',
                  'protocolVersion': '1',
                },
              }),
            );
            socket.add(
              jsonEncode({
                'type': 'server_ready',
                'eventId': 2,
                'payload': {
                  'serverTime': DateTime.now().toUtc().toIso8601String(),
                },
              }),
            );
          } catch (_) {
            // Client teardown can race with the server's test response.
          }
        });
      });

      final client = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        clientId: 'device-formal-0001',
        webSocketPath: '/api/v1/realtime',
        accessToken: 'secret-access-token',
        protocolVersion: '1',
        heartbeatInterval: const Duration(seconds: 30),
        heartbeatTimeout: const Duration(seconds: 30),
      );

      addTearDown(() async {
        await client.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });

      await client.connect();
      expect(client.state, RealtimeConnectionState.connected);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (receivedHello == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final payload = receivedHello?['payload'] as Map<String, dynamic>?;
      expect(payload?['clientId'], 'device-formal-0001');
      expect(payload?['accessToken'], 'secret-access-token');
      expect(payload?['protocolVersion'], '1');
    },
  );
}
