import 'dart:async';
import 'dart:io';

import 'package:realtime_poc/realtime_poc.dart';

Future<void> main(List<String> arguments) async {
  final baseUri = Uri.parse(
    arguments.isEmpty ? 'http://127.0.0.1:18473' : arguments.first,
  );
  final client = RealtimeClient(
    baseUri: baseUri,
    clientId: 'reconnect-smoke-${DateTime.now().microsecondsSinceEpoch}',
  );

  try {
    final firstReadyFuture = client.events
        .firstWhere((event) => event.type == 'server_ready')
        .timeout(const Duration(seconds: 8));
    await client.connect();
    final firstReady = await firstReadyFuture;
    stdout.writeln('FIRST_READY event=${firstReady.eventId}');

    final disconnectedFuture = client.states
        .firstWhere((state) => state == RealtimeConnectionState.disconnected)
        .timeout(const Duration(seconds: 12));
    final secondReadyFuture = client.events
        .firstWhere(
          (event) =>
              event.type == 'server_ready' &&
              event.eventId > firstReady.eventId,
        )
        .timeout(const Duration(seconds: 25));

    await disconnectedFuture;
    stdout.writeln('DISCONNECTED_DETECTED');
    final secondReady = await secondReadyFuture;

    final pongFuture = client.events
        .firstWhere(
          (event) =>
              event.type == 'pong' && event.eventId > secondReady.eventId,
        )
        .timeout(const Duration(seconds: 8));
    client.sendPing();
    final pong = await pongFuture;

    stdout.writeln(
      'RECONNECT_SMOKE_OK first=${firstReady.eventId} '
      'second=${secondReady.eventId} pong=${pong.eventId}',
    );
  } finally {
    await client.dispose();
  }
}
