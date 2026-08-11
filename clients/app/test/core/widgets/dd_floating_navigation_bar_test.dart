import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/widgets/dd_floating_navigation_bar.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets('floating navigation keeps margins, pill selection and badge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                const Expanded(child: SizedBox()),
                DdFloatingNavigationBar(
                  selectedIndex: selected,
                  onDestinationSelected: (value) =>
                      setState(() => selected = value),
                  destinations: const [
                    DdFloatingNavigationDestination(
                      icon: Stack(
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: SizedBox(
                              key: Key('test-unread-badge'),
                              width: 7,
                              height: 7,
                            ),
                          ),
                        ],
                      ),
                      selectedIcon: Stack(
                        children: [
                          Icon(Icons.chat_bubble_rounded),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: SizedBox(
                              key: Key('test-unread-badge'),
                              width: 7,
                              height: 7,
                            ),
                          ),
                        ],
                      ),
                      label: 'DD',
                    ),
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.people_outline_rounded),
                      selectedIcon: Icon(Icons.people_rounded),
                      label: '联系人',
                    ),
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore_rounded),
                      label: '发现',
                    ),
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: '我的',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final barRect = tester.getRect(
      find.byKey(const Key('dd-floating-navigation-bar')),
    );
    expect(barRect.left, closeTo(12, 0.1));
    expect(barRect.right, closeTo(348, 0.1));
    expect(barRect.height, closeTo(70, 0.1));
    expect(barRect.bottom, lessThan(640));
    expect(find.byKey(const Key('test-unread-badge')), findsOneWidget);

    final firstIndicator = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('dd-floating-navigation-indicator')),
    );
    expect(firstIndicator.left, 0);
    final firstIndicatorDecoration =
        (firstIndicator.child as DecoratedBox).decoration as BoxDecoration;
    expect(
      firstIndicatorDecoration.color,
      DdFloatingNavigationTokens.selectedSurface(Brightness.light),
    );
    expect(
      firstIndicatorDecoration.borderRadius,
      BorderRadius.circular(DdRadii.pill),
      reason: '选中态必须和 Telegram 一样使用真正的全圆角 pill，不能出现半吊子圆角。',
    );

    await tester.tap(find.byKey(const Key('dd-floating-navigation-item-1')));
    await tester.pump(DdFloatingNavigationTokens.animationDuration);
    expect(selected, 1);
    final secondIndicator = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('dd-floating-navigation-indicator')),
    );
    expect(secondIndicator.left, greaterThan(0));
    expect(find.byIcon(Icons.people_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid switching keeps one stable animated indicator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                const Expanded(child: SizedBox()),
                DdFloatingNavigationBar(
                  selectedIndex: selected,
                  onDestinationSelected: (value) =>
                      setState(() => selected = value),
                  destinations: const [
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.chat_bubble_outline_rounded),
                      selectedIcon: Icon(Icons.chat_bubble_rounded),
                      label: 'DD',
                    ),
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.people_outline_rounded),
                      selectedIcon: Icon(Icons.people_rounded),
                      label: '联系人',
                    ),
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore_rounded),
                      label: '发现',
                    ),
                    DdFloatingNavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: '我的',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final index in const [1, 3, 0, 2, 3, 1, 2]) {
      await tester.tap(find.byKey(Key('dd-floating-navigation-item-$index')));
      await tester.pump(const Duration(milliseconds: 18));
    }
    await tester.pumpAndSettle();

    expect(selected, 2);
    expect(
      find.byKey(const Key('dd-floating-navigation-indicator')),
      findsOneWidget,
    );
    final indicator = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('dd-floating-navigation-indicator')),
    );
    expect(indicator.left, greaterThan(0));
    expect(find.byIcon(Icons.explore_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating navigation uses dark surface and hides for keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget buildBar({required bool hidden}) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox()),
            DdFloatingNavigationBar(
              selectedIndex: 0,
              hidden: hidden,
              onDestinationSelected: _noop,
              destinations: const [
                DdFloatingNavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline_rounded),
                  selectedIcon: Icon(Icons.chat_bubble_rounded),
                  label: 'DD',
                ),
                DdFloatingNavigationDestination(
                  icon: Icon(Icons.people_outline_rounded),
                  selectedIcon: Icon(Icons.people_rounded),
                  label: '联系人',
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(buildBar(hidden: false));
    await tester.pumpAndSettle();
    final bar = tester.widget<Container>(
      find.byKey(const Key('dd-floating-navigation-bar')),
    );
    expect(
      (bar.decoration! as BoxDecoration).color,
      DdFloatingNavigationTokens.surface(Brightness.dark),
    );

    await tester.pumpWidget(buildBar(hidden: true));
    await tester.pump();
    expect(
      find.byKey(const Key('dd-floating-navigation-hidden')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dd-floating-navigation-bar')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

void _noop(int _) {}
