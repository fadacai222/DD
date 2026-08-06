import 'dart:async';
import 'dart:io';

import 'package:realtime_poc/realtime_poc.dart';

Future<void> main(List<String> arguments) async {
  final baseUri = Uri.parse(
    arguments.isEmpty ? 'http://127.0.0.1:18473' : arguments.first,
  );
  final client = RealtimeClient(
    baseUri: baseUri,
    clientId: 'dart-poc-${DateTime.now().millisecondsSinceEpoch}',
  );

  final subscriptions = <StreamSubscription<dynamic>>[
    client.states.listen((state) => stdout.writeln('state: ${state.name}')),
    client.events.listen((event) {
      stdout.writeln(
        'event: type=${event.type} eventId=${event.eventId} '
        'requestId=${event.requestId} payload=${event.payload}',
      );
      if (event.error != null) {
        stdout.writeln(
          'error event: ${event.error!.code} ${event.error!.message}',
        );
      }
    }),
    client.errors.listen((error) => stderr.writeln('client error: $error')),
  ];

  try {
    final health = await client.fetchHealth();
    stdout.writeln('health: $health');

    await client.connect();
    final pingTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        if (client.state == RealtimeConnectionState.connected) {
          client.sendPing();
        }
      },
    );

    await ProcessSignal.sigint.watch().first;
    pingTimer.cancel();
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await client.dispose();
  }
}
