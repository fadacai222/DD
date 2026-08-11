import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android FileProvider exposes only DD transfer/share cache directories', () {
    final resource = File('android/app/src/main/res/xml/dd_file_paths.xml');
    expect(resource.existsSync(), isTrue);

    final xml = resource.readAsStringSync();
    expect(
      xml,
      contains('<files-path name="dd_transfers" path="DD/transfers/" />'),
    );
    expect(
      xml,
      contains('<cache-path name="dd_shared_files" path="dd_shared_files/" />'),
    );
    expect(xml, isNot(contains('<files-path name="dd_files" path="."')));
    expect(xml, isNot(contains('<root-path')));
  });

  test('Android APK open uses the package installer contract', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/org/openimx/client/MainActivity.kt',
    ).readAsStringSync();
    final chatPage = File(
      'lib/features/messaging/presentation/text_chat_page.dart',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android.permission.REQUEST_INSTALL_PACKAGES'),
    );
    expect(activity, contains('Intent.ACTION_INSTALL_PACKAGE'));
    expect(activity, contains('application/vnd.android.package-archive'));
    expect(chatPage, contains("lower.endsWith('.apk')"));
    expect(chatPage, contains("'application/vnd.android.package-archive'"));
  });
}
