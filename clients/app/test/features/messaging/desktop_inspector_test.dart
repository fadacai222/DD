import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/presentation/desktop_inspector.dart';

void main() {
  test('inspector controller keeps an explicit secondary-page stack', () {
    final controller = DesktopInspectorController();
    addTearDown(controller.dispose);

    controller.open(
      DesktopInspectorEntry(
        id: 'details',
        title: '聊天详情',
        builder: (_) => const Text('details'),
      ),
    );
    controller.push(
      DesktopInspectorEntry(
        id: 'media',
        title: '聊天文件',
        builder: (_) => const Text('media'),
      ),
    );

    expect(controller.isOpen, isTrue);
    expect(controller.canPop, isTrue);
    expect(controller.current?.id, 'media');

    controller.pop();
    expect(controller.current?.id, 'details');
    expect(controller.canPop, isFalse);

    controller.pop();
    expect(controller.isOpen, isFalse);
  });

  testWidgets('narrow desktop inspector overlays instead of replacing content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = DesktopInspectorController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(
              key: Key('chat-remains-visible'),
              color: Colors.white,
            ),
            DesktopInspectorOverlay(controller: controller),
          ],
        ),
      ),
    );

    controller.open(
      DesktopInspectorEntry(
        id: 'details',
        title: '聊天详情',
        builder: (_) => const Text('详情内容'),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-remains-visible')), findsOneWidget);
    expect(find.byKey(const Key('desktop-right-inspector')), findsOneWidget);
    expect(find.text('详情内容'), findsOneWidget);
    expect(find.byKey(const Key('desktop-inspector-barrier')), findsOneWidget);

    await tester.tap(find.byKey(const Key('desktop-inspector-barrier')));
    await tester.pump();
    expect(find.byKey(const Key('desktop-right-inspector')), findsNothing);
    expect(find.byKey(const Key('chat-remains-visible')), findsOneWidget);
  });

  testWidgets('right inspector back preserves parent details before closing', (
    tester,
  ) async {
    final controller = DesktopInspectorController();
    addTearDown(controller.dispose);
    controller.open(
      DesktopInspectorEntry(
        id: 'details',
        title: '聊天详情',
        builder: (_) => const Text('父级详情'),
      ),
    );
    controller.push(
      DesktopInspectorEntry(
        id: 'media',
        title: '聊天文件',
        builder: (_) => const Text('二级页面'),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: RightInspectorPane(controller: controller)),
    );
    expect(find.text('二级页面'), findsOneWidget);

    await tester.tap(find.byKey(const Key('desktop-inspector-back')));
    await tester.pump();
    expect(find.text('父级详情'), findsOneWidget);
    expect(find.text('二级页面'), findsNothing);
  });
}
