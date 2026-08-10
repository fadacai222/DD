import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/core/theme/app_theme_mode_store.dart';

void main() {
  test('loads persisted dark mode and writes later changes', () async {
    final storage = _MemoryStore(<String, String>{
      AppThemeModeStore.storageKey: 'dark',
    });
    final store = AppThemeModeStore(storage: storage);

    await store.load();
    expect(store.mode, ThemeMode.dark);
    expect(store.label, '深色');

    await store.setMode(ThemeMode.light);
    expect(store.mode, ThemeMode.light);
    expect(storage.values[AppThemeModeStore.storageKey], 'light');
  });

  test('unknown persisted value safely falls back to system', () async {
    final storage = _MemoryStore(<String, String>{
      AppThemeModeStore.storageKey: 'future-mode',
    });
    final store = AppThemeModeStore(storage: storage);

    await store.load();
    expect(store.mode, ThemeMode.system);
    expect(store.label, '跟随系统');
  });

  test('failed persistence rolls visible mode back', () async {
    final storage = _MemoryStore()..failWrites = true;
    final store = AppThemeModeStore(storage: storage);
    await store.load();

    await expectLater(
      store.setMode(ThemeMode.dark),
      throwsA(isA<StateError>()),
    );
    expect(store.mode, ThemeMode.system);
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  _MemoryStore([Map<String, String>? initial])
    : values = Map<String, String>.of(initial ?? const {});

  final Map<String, String> values;
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
