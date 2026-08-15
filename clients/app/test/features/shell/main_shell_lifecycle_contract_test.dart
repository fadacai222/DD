import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MainShell resumed keeps all recovery hooks including messaging', () {
    final source = File(
      'lib/features/shell/presentation/main_shell_page.dart',
    ).readAsStringSync();
    final lifecycleStart = source.indexOf(
      'void didChangeAppLifecycleState(AppLifecycleState state)',
    );
    final disposeStart = source.indexOf('void dispose()', lifecycleStart);

    expect(lifecycleStart, greaterThanOrEqualTo(0));
    expect(disposeStart, greaterThan(lifecycleStart));

    final lifecycleBody = source.substring(lifecycleStart, disposeStart);
    expect(lifecycleBody, contains('if (state == AppLifecycleState.resumed)'));
    expect(lifecycleBody, contains('_messagingCoordinator.onAppResumed()'));
    expect(lifecycleBody, contains('_momentActivityController.refresh()'));
    expect(lifecycleBody, contains('_pushRegistrationService.onAppResumed()'));
    expect(
      lifecycleBody,
      contains('_recoverCallFromExternalSignal(clearWhenMissing: true)'),
    );
    expect(lifecycleBody, contains('_syncNotificationBadge()'));
  });
}
