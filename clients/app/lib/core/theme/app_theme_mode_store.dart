import 'dart:async';

import 'package:flutter/material.dart';

import '../logging/client_log.dart';
import '../security/dd_secure_storage.dart';

/// Process-wide, persisted appearance preference.
///
/// Theme selection is intentionally client-local: it must work before login and
/// must not depend on a server round-trip just to paint the application shell.
final class AppThemeModeStore extends ChangeNotifier {
  AppThemeModeStore({SecureKeyValueStore? storage})
    : _storage = storage ?? DdSecureStorage.shared;

  static final AppThemeModeStore shared = AppThemeModeStore();
  static const String storageKey = 'dd.appearance.theme-mode.v1';

  final SecureKeyValueStore _storage;
  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;
  Future<void>? _loading;

  ThemeMode get mode => _mode;
  bool get loaded => _loaded;

  String get label => switch (_mode) {
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
    ThemeMode.system => '跟随系统',
  };

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadInternal();
  }

  Future<void> _loadInternal() async {
    try {
      _mode = _decode(await _storage.read(storageKey));
    } catch (error, stackTrace) {
      _mode = ThemeMode.system;
      unawaited(
        ClientLog.error(
          'theme-mode preference load failed; using system default',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    } finally {
      _loaded = true;
      _loading = null;
      notifyListeners();
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    await load();
    if (_mode == mode) return;
    final previous = _mode;
    _mode = mode;
    notifyListeners();
    try {
      await _storage.write(storageKey, _encode(mode));
    } catch (error, stackTrace) {
      // Do not pretend a preference was saved when secure storage failed.
      _mode = previous;
      notifyListeners();
      unawaited(
        ClientLog.error(
          'theme-mode preference save failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  static ThemeMode _decode(String? raw) => switch (raw?.trim().toLowerCase()) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _encode(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}
