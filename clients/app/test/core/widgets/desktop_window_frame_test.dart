import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/window/desktop_window_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('dd/window');

  testWidgets('Windows Escape requests navigation back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var backRequests = 0;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopWindowFrame(
            onBackRequested: () => backRequests++,
            child: const Scaffold(
              body: TextField(key: Key('escape-focus-field')),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('escape-focus-field')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(backRequests, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows Escape pops the top route but never exits the root', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final navigatorKey = GlobalKey<NavigatorState>();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopWindowFrame(
            onBackRequested: () {
              final navigator = navigatorKey.currentState;
              if (navigator != null) unawaited(navigator.maybePop());
            },
            child: Navigator(
              key: navigatorKey,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('root-page')),
              ),
            ),
          ),
        ),
      );

      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: TextField(key: Key('second-route-field'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('second-route-field')), findsOneWidget);

      await tester.tap(find.byKey(const Key('second-route-field')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('root-page'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('root-page'), findsOneWidget);
      expect(navigatorKey.currentState!.canPop(), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local Escape handler wins over desktop back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var backRequests = 0;
    var localEscapes = 0;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopWindowFrame(
            onBackRequested: () => backRequests++,
            child: Scaffold(
              body: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      localEscapes++,
                },
                child: const TextField(key: Key('local-escape-field')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('local-escape-field')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(localEscapes, 1);
      expect(backRequests, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows close button hides the app to the system tray', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'isMaximized') return false;
      return null;
    });

    try {
      await tester.pumpWidget(
        const MaterialApp(home: DesktopWindowFrame(child: SizedBox.expand())),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('关闭到托盘'));
      await tester.pump();

      expect(calls, contains('hideToTray'));
      expect(calls, isNot(contains('close')));
    } finally {
      messenger.setMockMethodCallHandler(windowChannel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
