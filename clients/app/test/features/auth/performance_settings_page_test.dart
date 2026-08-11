import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/performance/app_performance_store.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/auth/presentation/performance_settings_page.dart';

void main() {
  testWidgets('Windows performance panel exposes real GPU and media controls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final store = AppPerformanceStore(storage: _MemoryStore());
      await store.load();

      await tester.pumpWidget(
        MaterialApp(home: PerformanceSettingsPage(store: store)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('performance-windows-gpu')), findsOneWidget);
      expect(find.text('高性能'), findsOneWidget);
      expect(
        find.byKey(const Key('performance-hardware-video')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('performance-video-autoplay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('performance-reduce-motion')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('performance-power-saving')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.powerSaving, isTrue);
      expect(store.effectiveReduceMotion, isTrue);
      expect(store.effectiveAutoPlayVideoPreviews, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
