import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  test('snackbars are floating with stable safe margins', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
      expect(
        theme.snackBarTheme.insetPadding,
        const EdgeInsets.fromLTRB(16, 0, 16, 16),
      );
      expect(theme.snackBarTheme.shape, isA<RoundedRectangleBorder>());
    }
  });
}
