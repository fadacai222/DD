import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/widgets/dd_action_sheet.dart';

void main() {
  testWidgets('点击菜单外空白区域会关闭 DdActionSheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () {
                  showDdActionSheet<String>(
                    context,
                    items: const [
                      DdActionSheetItem(
                        value: 'reply',
                        icon: Icons.reply_rounded,
                        label: '回复',
                      ),
                      DdActionSheetItem(
                        value: 'delete',
                        icon: Icons.delete_outline_rounded,
                        label: '仅本地删除',
                        destructive: true,
                      ),
                    ],
                  );
                },
                child: const Text('打开菜单'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    expect(find.text('回复'), findsOneWidget);

    // 模拟用户点击白色菜单正上方、但仍落在 BottomSheet 路由范围内的聊天空白区。
    // 这是 Android 真机最容易出现“看起来是空白，其实被透明 sheet 吃掉点击”的位置。
    final menuRect = tester.getRect(find.byType(SingleChildScrollView));
    final routeRect = tester.getRect(find.byType(BottomSheet));
    expect(routeRect.top, lessThan(menuRect.top));
    final blankY = routeRect.top + ((menuRect.top - routeRect.top) / 2);
    await tester.tapAt(Offset(20, blankY));
    await tester.pumpAndSettle();

    expect(find.text('回复'), findsNothing);
    expect(find.text('仅本地删除'), findsNothing);
  });

  testWidgets('点击菜单项仍返回对应动作，不会被空白关闭层抢事件', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  selected = await showDdActionSheet<String>(
                    context,
                    items: const [
                      DdActionSheetItem(
                        value: 'reply',
                        icon: Icons.reply_rounded,
                        label: '回复',
                      ),
                    ],
                  );
                },
                child: const Text('打开菜单'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();

    expect(selected, 'reply');
    expect(find.text('回复'), findsNothing);
  });

  testWidgets('嵌套 Navigator 中点击空白只关闭 ActionSheet，不会误退聊天页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    showDdActionSheet<String>(
                      context,
                      items: const [
                        DdActionSheetItem(
                          value: 'reply',
                          icon: Icons.reply_rounded,
                          label: '回复',
                        ),
                      ],
                    );
                  },
                  child: const Text('聊天页打开菜单'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('聊天页打开菜单'));
    await tester.pumpAndSettle();
    expect(find.text('回复'), findsOneWidget);

    final menuRect = tester.getRect(find.byType(SingleChildScrollView));
    await tester.tapAt(Offset(20, menuRect.top - 20));
    await tester.pumpAndSettle();

    expect(find.text('回复'), findsNothing);
    expect(find.text('聊天页打开菜单'), findsOneWidget);
  });
}
