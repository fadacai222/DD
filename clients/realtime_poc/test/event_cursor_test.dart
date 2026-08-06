import 'package:realtime_poc/realtime_poc.dart';
import 'package:test/test.dart';

void main() {
  test('accepts increasing event IDs and rejects duplicates', () {
    final cursor = EventCursor();

    expect(cursor.accept(1), isTrue);
    expect(cursor.accept(2), isTrue);
    expect(cursor.accept(2), isFalse);
    expect(cursor.accept(1), isFalse);
    expect(cursor.accept(3), isTrue);
    expect(cursor.lastEventId, 3);
  });

  test('accepts non-persistent events without moving the cursor', () {
    final cursor = EventCursor(initialEventId: 7);

    expect(cursor.accept(0), isTrue);
    expect(cursor.lastEventId, 7);
  });
}
