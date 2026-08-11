import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/performance/app_performance_store.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';

void main() {
  test(
    'loads persisted performance preferences and derives power saving',
    () async {
      final storage = _MemoryStore(<String, String>{
        AppPerformanceStore.storageKey: jsonEncode(<String, Object>{
          'powerSaving': true,
          'reduceMotion': false,
          'autoPlayVideoPreviews': true,
          'hardwareVideoDecoding': false,
        }),
      });
      final store = AppPerformanceStore(storage: storage);

      await store.load();

      expect(store.powerSaving, isTrue);
      expect(store.hardwareVideoDecoding, isFalse);
      expect(store.effectiveReduceMotion, isTrue);
      expect(store.effectiveAutoPlayVideoPreviews, isFalse);
    },
  );

  test(
    'performance switches persist without mixing device-local defaults',
    () async {
      final storage = _MemoryStore();
      final store = AppPerformanceStore(storage: storage);
      await store.load();

      await store.setReduceMotion(true);
      await store.setAutoPlayVideoPreviews(false);
      await store.setHardwareVideoDecoding(false);

      final raw = storage.values[AppPerformanceStore.storageKey];
      final json = jsonDecode(raw!) as Map<String, dynamic>;
      expect(json['reduceMotion'], isTrue);
      expect(json['autoPlayVideoPreviews'], isFalse);
      expect(json['hardwareVideoDecoding'], isFalse);
      expect(json['powerSaving'], isFalse);
    },
  );

  test('failed persistence rolls visible performance state back', () async {
    final storage = _MemoryStore()..failWrites = true;
    final store = AppPerformanceStore(storage: storage);
    await store.load();

    await expectLater(store.setPowerSaving(true), throwsA(isA<StateError>()));
    expect(store.powerSaving, isFalse);
    expect(store.effectiveAutoPlayVideoPreviews, isTrue);
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
