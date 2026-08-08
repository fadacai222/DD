import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/home/debug_console_home.dart';

void main() {
  testWidgets('renders all modules on desktop without layout exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: DebugConsoleHome()));
    await tester.pump();

    expect(find.text('实时通信'), findsOneWidget);
    expect(find.text('音视频通话'), findsOneWidget);
    expect(find.text('双端通话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
