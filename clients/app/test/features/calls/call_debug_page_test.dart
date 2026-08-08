import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/presentation/call_debug_controller.dart';
import 'package:im_client/features/calls/presentation/call_debug_page.dart';
import 'package:im_client/features/calls/presentation/widgets/call_video_grid.dart';

import '../../support/fake_call_token_provider.dart';

void main() {
  testWidgets('renders the disconnected call console on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = CallDebugController(
      tokenProvider: FakeCallTokenProvider(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: CallDebugPage(controller: controller)),
    );
    await tester.pump();

    expect(find.text('音视频通话 PoC'), findsOneWidget);
    expect(find.byKey(const ValueKey('joinCallButton')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
    await tester.pumpAndSettle();

    expect(find.byType(CallVideoGrid), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
