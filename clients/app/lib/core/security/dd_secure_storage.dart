import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Single process-wide gate around flutter_secure_storage.
///
/// On Windows the plugin stores all keys in one encrypted JSON file. Multiple
/// concurrent read-modify-write calls can race against each other and corrupt
/// that file, so every secure-storage operation in DD must pass through this
/// serialized gateway.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class DdSecureStorage implements SecureKeyValueStore {
  DdSecureStorage._({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final DdSecureStorage shared = DdSecureStorage._();

  final FlutterSecureStorage _storage;

  static Future<void> _tail = Future<void>.value();

  @override
  Future<String?> read(String key) => _enqueue(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) =>
      _enqueue(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete(String key) => _enqueue(() => _storage.delete(key: key));

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = () async {
      try {
        await previous;
      } catch (_) {
        // A previous caller receives its own error. The queue itself must keep
        // moving or every later storage operation would be permanently stuck.
      }
      try {
        completer.complete(await _withRetry(action));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await action();
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt == 2) break;
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 0 ? 50 : 150),
        );
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }
}
