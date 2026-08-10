import 'dart:async';
import 'dart:io';

final class ClientLog {
  const ClientLog._();

  static const int _maxBytes = 2 * 1024 * 1024;
  static Future<void> _tail = Future<void>.value();
  static String? _path;

  static String? get path => _path ??= _resolvePath();

  static Future<void> info(String message) => _enqueue('INFO', message);

  static Future<void> error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final buffer = StringBuffer(message);
    if (error != null) buffer.write(' | $error');
    if (stackTrace != null) buffer.write('\n$stackTrace');
    return _enqueue('ERROR', buffer.toString());
  }

  static Future<void> _enqueue(String level, String message) {
    _tail = _tail.then((_) => _write(level, message)).catchError((_) {});
    return _tail;
  }

  static Future<void> _write(String level, String message) async {
    final logPath = path;
    if (logPath == null) return;
    final file = File(logPath);
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() > _maxBytes) {
      final rotated = File('$logPath.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
    }
    final normalized = message
        .replaceAll(
          RegExp(r'Bearer\s+[A-Za-z0-9._~+\-/=]+', caseSensitive: false),
          'Bearer [REDACTED]',
        )
        .replaceAll(RegExp(r'\s+$'), '');
    final line = '${DateTime.now().toIso8601String()} [$level] $normalized\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  static String? _resolvePath() {
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null && local.trim().isNotEmpty) {
        return '$local${Platform.pathSeparator}DD${Platform.pathSeparator}logs${Platform.pathSeparator}dd-client.log';
      }
    }
    try {
      return '${Directory.systemTemp.path}${Platform.pathSeparator}dd-client.log';
    } catch (_) {
      return null;
    }
  }
}
