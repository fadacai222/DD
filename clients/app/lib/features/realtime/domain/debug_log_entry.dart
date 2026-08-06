enum DebugLogLevel { info, success, warning, error }

final class DebugLogEntry {
  const DebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final DebugLogLevel level;
  final String message;
}
