import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../logging/client_log.dart';
import '../security/dd_secure_storage.dart';

final class AppPerformancePreferences {
  const AppPerformancePreferences({
    this.powerSaving = false,
    this.reduceMotion = false,
    this.autoPlayVideoPreviews = true,
    this.hardwareVideoDecoding = true,
  });

  final bool powerSaving;
  final bool reduceMotion;
  final bool autoPlayVideoPreviews;
  final bool hardwareVideoDecoding;

  AppPerformancePreferences copyWith({
    bool? powerSaving,
    bool? reduceMotion,
    bool? autoPlayVideoPreviews,
    bool? hardwareVideoDecoding,
  }) => AppPerformancePreferences(
    powerSaving: powerSaving ?? this.powerSaving,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    autoPlayVideoPreviews: autoPlayVideoPreviews ?? this.autoPlayVideoPreviews,
    hardwareVideoDecoding: hardwareVideoDecoding ?? this.hardwareVideoDecoding,
  );

  Map<String, Object> toJson() => <String, Object>{
    'powerSaving': powerSaving,
    'reduceMotion': reduceMotion,
    'autoPlayVideoPreviews': autoPlayVideoPreviews,
    'hardwareVideoDecoding': hardwareVideoDecoding,
  };

  static AppPerformancePreferences fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return const AppPerformancePreferences();
    }
    return AppPerformancePreferences(
      powerSaving: raw['powerSaving'] is bool
          ? raw['powerSaving'] as bool
          : false,
      reduceMotion: raw['reduceMotion'] is bool
          ? raw['reduceMotion'] as bool
          : false,
      autoPlayVideoPreviews: raw['autoPlayVideoPreviews'] is bool
          ? raw['autoPlayVideoPreviews'] as bool
          : true,
      hardwareVideoDecoding: raw['hardwareVideoDecoding'] is bool
          ? raw['hardwareVideoDecoding'] as bool
          : true,
    );
  }
}

/// Process-wide, device-local performance preferences.
///
/// These switches intentionally stay local instead of syncing through the DD
/// account. GPU drivers, battery constraints and preferred motion levels are
/// properties of a specific device, not the user's server profile.
final class AppPerformanceStore extends ChangeNotifier {
  AppPerformanceStore({SecureKeyValueStore? storage})
    : _storage = storage ?? DdSecureStorage.shared;

  static final AppPerformanceStore shared = AppPerformanceStore();
  static const String storageKey = 'dd.performance.preferences.v1';

  final SecureKeyValueStore _storage;
  AppPerformancePreferences _value = const AppPerformancePreferences();
  bool _loaded = false;
  Future<void>? _loading;

  AppPerformancePreferences get value => _value;
  bool get loaded => _loaded;

  bool get powerSaving => _value.powerSaving;
  bool get reduceMotion => _value.reduceMotion;
  bool get autoPlayVideoPreviews => _value.autoPlayVideoPreviews;
  bool get hardwareVideoDecoding => _value.hardwareVideoDecoding;

  bool get effectiveReduceMotion => powerSaving || reduceMotion;
  bool get effectiveAutoPlayVideoPreviews =>
      !powerSaving && autoPlayVideoPreviews;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadInternal();
  }

  Future<void> _loadInternal() async {
    try {
      final raw = await _storage.read(storageKey);
      if (raw != null && raw.trim().isNotEmpty) {
        _value = AppPerformancePreferences.fromJson(jsonDecode(raw));
      }
    } catch (error, stackTrace) {
      _value = const AppPerformancePreferences();
      unawaited(
        ClientLog.error(
          'performance preference load failed; using defaults',
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

  Future<void> setPowerSaving(bool value) =>
      _save(_value.copyWith(powerSaving: value));

  Future<void> setReduceMotion(bool value) =>
      _save(_value.copyWith(reduceMotion: value));

  Future<void> setAutoPlayVideoPreviews(bool value) =>
      _save(_value.copyWith(autoPlayVideoPreviews: value));

  Future<void> setHardwareVideoDecoding(bool value) =>
      _save(_value.copyWith(hardwareVideoDecoding: value));

  Future<void> _save(AppPerformancePreferences next) async {
    await load();
    if (_same(_value, next)) return;
    final previous = _value;
    _value = next;
    notifyListeners();
    try {
      await _storage.write(storageKey, jsonEncode(next.toJson()));
    } catch (error, stackTrace) {
      _value = previous;
      notifyListeners();
      unawaited(
        ClientLog.error(
          'performance preference save failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  bool _same(AppPerformancePreferences a, AppPerformancePreferences b) =>
      a.powerSaving == b.powerSaving &&
      a.reduceMotion == b.reduceMotion &&
      a.autoPlayVideoPreviews == b.autoPlayVideoPreviews &&
      a.hardwareVideoDecoding == b.hardwareVideoDecoding;
}
