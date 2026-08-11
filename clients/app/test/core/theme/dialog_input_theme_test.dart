import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  test(
    'forms use neutral compact outlines instead of green pill focus rings',
    () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final input = theme.inputDecorationTheme;
        final border = input.border! as OutlineInputBorder;
        final focused = input.focusedBorder! as OutlineInputBorder;

        expect(border.borderRadius.topLeft.x, DdRadii.input);
        expect(focused.borderRadius.topLeft.x, DdRadii.input);
        expect(focused.borderSide.color, isNot(DdColors.green));
        expect(focused.borderSide.color, isNot(DdColors.greenPressed));
      }
    },
  );

  test('dialogs use neutral surfaces and restrained corner radius', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final dialog = theme.dialogTheme;
      final shape = dialog.shape! as RoundedRectangleBorder;
      final radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;

      expect(radius, DdRadii.dialog);
      expect(dialog.surfaceTintColor, Colors.transparent);
      expect(dialog.backgroundColor, theme.colorScheme.surface);
    }
  });

  test('primary buttons no longer inherit full pill geometry', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final shape =
          theme.filledButtonTheme.style!.shape!.resolve(<WidgetState>{})!
              as RoundedRectangleBorder;
      final radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;

      expect(radius, DdRadii.input);
      expect(radius, lessThan(DdRadii.surface));
    }
  });
}
