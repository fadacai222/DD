import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  test('snackbars stay above persistent bottom controls globally', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
      expect(theme.snackBarTheme.width, 320);
      expect(
        theme.snackBarTheme.insetPadding,
        const EdgeInsets.fromLTRB(
          16,
          0,
          16,
          DdFeedbackTokens.snackBarBottomInset,
        ),
      );
      expect(
        DdFeedbackTokens.snackBarBottomInset,
        greaterThan(
          DdFloatingNavigationTokens.height +
              DdFloatingNavigationTokens.bottomGap,
        ),
      );
      expect(theme.snackBarTheme.shape, isA<RoundedRectangleBorder>());
    }
  });

  testWidgets('floating snackbar never overlaps the reserved bottom UI zone', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final size in const [Size(881, 657), Size(390, 844)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height:
                      DdFloatingNavigationTokens.height +
                      DdFloatingNavigationTokens.bottomGap,
                  child: ColoredBox(
                    key: Key('persistent-bottom-controls'),
                    color: Colors.white,
                  ),
                ),
                Builder(
                  builder: (context) => Align(
                    alignment: Alignment.topCenter,
                    child: TextButton(
                      onPressed: () {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('已收藏')));
                      },
                      child: const Text('show'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('show'));
      await tester.pump(const Duration(milliseconds: 300));

      final feedbackTextBottom = tester.getBottomLeft(find.text('已收藏')).dy;
      final bottomControlsTop = tester
          .getTopLeft(find.byKey(const Key('persistent-bottom-controls')))
          .dy;

      expect(feedbackTextBottom, lessThan(bottomControlsTop), reason: '$size');
    }
  });
}
