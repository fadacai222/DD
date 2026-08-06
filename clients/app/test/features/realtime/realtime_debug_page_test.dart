import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/realtime/presentation/realtime_debug_controller.dart';
import 'package:im_client/features/realtime/presentation/realtime_debug_page.dart';

import '../../support/fake_realtime_gateway.dart';

void main() {
  testWidgets('renders without overflow on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = RealtimeDebugController(
      gatewayFactory: (baseUri, clientId) => FakeRealtimeGateway(),
      clientId: 'widget-test',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RealtimeDebugPage(controller: controller)),
    );
    await tester.pump();

    expect(find.text('实时通信调试台'), findsOneWidget);
    expect(find.byKey(const ValueKey('serverUrlField')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connect action updates the visible connection state', (
    tester,
  ) async {
    final gateway = FakeRealtimeGateway();
    final controller = RealtimeDebugController(
      gatewayFactory: (baseUri, clientId) => gateway,
      clientId: 'widget-test',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RealtimeDebugPage(controller: controller)),
    );

    await tester.tap(find.byKey(const ValueKey('connectButton')));
    await tester.pumpAndSettle();

    expect(find.text('已连接'), findsOneWidget);
    expect(gateway.connectCalls, 1);
    expect(find.textContaining('WebSocket 已连接'), findsOneWidget);
  });

  testWidgets('invalid server URL is reported in the event log', (
    tester,
  ) async {
    final controller = RealtimeDebugController(
      gatewayFactory: (baseUri, clientId) => FakeRealtimeGateway(),
      clientId: 'widget-test',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RealtimeDebugPage(controller: controller)),
    );

    await tester.enterText(
      find.byKey(const ValueKey('serverUrlField')),
      'ftp://127.0.0.1',
    );
    await tester.tap(find.byKey(const ValueKey('healthButton')));
    await tester.pump();

    expect(find.textContaining('服务器地址无效'), findsOneWidget);
  });
}
