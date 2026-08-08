import 'dart:convert';
import 'dart:io';

import 'package:realtime_poc/realtime_poc.dart';
import 'package:test/test.dart';

void main() {
  test('heartbeat replaces a half-open websocket and reconnects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var connectionCount = 0;
    var eventID = 0;
    var respondToHeartbeat = true;
    final sockets = <WebSocket>[];

    void sendJson(WebSocket socket, Map<String, dynamic> message) {
      try {
        if (socket.readyState == WebSocket.open) {
          socket.add(jsonEncode(message));
        }
      } catch (_) {
        // The client may close the half-open socket while the test server is
        // about to answer; that race is expected and not part of the assertion.
      }
    }

    server.listen((request) async {
      if (request.uri.path != '/ws') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // Count the accepted WebSocket request before awaiting the server-side
      // upgrade continuation. The client can observe `channel.ready` as soon as
      // the handshake completes, while this async callback may resume a moment
      // later; incrementing only after `await upgrade` made the connected-state
      // assertion depend on scheduler timing and caused a flaky timeout.
      connectionCount++;
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((rawMessage) {
        if (rawMessage is! String) return;
        final message = jsonDecode(rawMessage) as Map<String, dynamic>;
        final type = message['type'] as String? ?? '';
        final requestID = message['requestId'] as String? ?? '';

        if (type == 'hello') {
          sendJson(socket, <String, dynamic>{
            'type': 'hello_ack',
            'requestId': requestID,
            'eventId': ++eventID,
            'payload': <String, dynamic>{
              'connectionId': 'test-$connectionCount',
              'protocolVersion': 1,
            },
          });
          return;
        }

        if (type == 'ping' && respondToHeartbeat) {
          sendJson(socket, <String, dynamic>{
            'type': 'pong',
            'requestId': requestID,
            'eventId': ++eventID,
            'payload': <String, dynamic>{},
          });
        }
      });
    });

    final client = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      clientId: 'android-test',
      heartbeatInterval: const Duration(milliseconds: 80),
      heartbeatTimeout: const Duration(milliseconds: 120),
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
    expect(connectionCount, 1);

    // Simulate Android losing Wi-Fi without either TCP endpoint receiving a
    // close/error. The socket remains open but stops answering application
    // heartbeats, which is the half-open state seen on mobile networks.
    respondToHeartbeat = false;

    await client.states
        .firstWhere((state) => state == RealtimeConnectionState.disconnected)
        .timeout(const Duration(seconds: 2));

    respondToHeartbeat = true;

    await client.states
        .firstWhere(
          (state) =>
              state == RealtimeConnectionState.connected &&
              connectionCount >= 2,
        )
        .timeout(const Duration(seconds: 3));

    expect(connectionCount, greaterThanOrEqualTo(2));
    expect(client.state, RealtimeConnectionState.connected);
  });
}
