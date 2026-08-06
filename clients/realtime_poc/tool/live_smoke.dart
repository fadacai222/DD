import 'dart:async';
import 'dart:io';

import 'package:realtime_poc/realtime_poc.dart';

Future<void> main(List<String> arguments) async {
  final baseUri = Uri.parse(
    arguments.isEmpty ? 'http://127.0.0.1:18473' : arguments.first,
  );
  final client = RealtimeClient(
    baseUri: baseUri,
    clientId: 'live-smoke-${DateTime.now().microsecondsSinceEpoch}',
  );

  try {
    final health = await client.fetchHealth().timeout(
      const Duration(seconds: 5),
    );
    if (health['status'] != 'ok') {
      throw StateError('Unexpected health response: $health');
    }

    final readyFuture = client.events
        .firstWhere((event) => event.type == 'server_ready')
        .timeout(const Duration(seconds: 5));
    await client.connect();
    final ready = await readyFuture;

    final pongFuture = client.events
        .firstWhere((event) => event.type == 'pong')
        .timeout(const Duration(seconds: 5));
    client.sendPing();
    final pong = await pongFuture;

    stdout.writeln(
      'LIVE_SMOKE_OK service=${health['service']} '
      'readyEvent=${ready.eventId} pongEvent=${pong.eventId}',
    );
  } finally {
    await client.dispose();
  }
}
