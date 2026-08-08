import 'dart:convert';
import 'dart:io';

import 'package:dd_realtime_protocol/realtime_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('shared fixtures decode and round-trip', () {
    final cases = <String, RealtimeType>{
      'hello.json': RealtimeType.hello,
      'event_available.json': RealtimeType.eventAvailable,
      'ping.json': RealtimeType.ping,
    };

    for (final entry in cases.entries) {
      final json = jsonDecode(File('fixtures/${entry.key}').readAsStringSync())
          as Map<String, dynamic>;
      final envelope = RealtimeEnvelope.fromJson(json);
      expect(envelope.type, entry.value);
      final roundTrip = RealtimeEnvelope.fromJson(envelope.toJson());
      expect(roundTrip.type, envelope.type);
    }
  });

  test('invalid protocol data is rejected', () {
    expect(
      () => RealtimeEnvelope.fromJson(<String, dynamic>{
        'type': 'HELLO',
        'protocolVersion': 2,
        'deviceId': 'dev_fixture01',
        'lastCursor': null,
      }),
      throwsFormatException,
    );
    expect(
      () => RealtimeEnvelope.fromJson(<String, dynamic>{
        'type': 'EVENT_AVAILABLE',
        'eventId': 'evt_fixture01',
        'cursor': '',
      }),
      throwsFormatException,
    );
  });
}
