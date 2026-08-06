final class EventCursor {
  EventCursor({int initialEventId = 0}) : _lastEventId = initialEventId;

  int _lastEventId;

  int get lastEventId => _lastEventId;

  bool accept(int eventId) {
    if (eventId <= 0) {
      return true;
    }
    if (eventId <= _lastEventId) {
      return false;
    }
    _lastEventId = eventId;
    return true;
  }
}
