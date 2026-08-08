enum CallLogLevel { info, success, warning, error }

final class CallLogEntry {
  const CallLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final CallLogLevel level;
  final String message;
}
