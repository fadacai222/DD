import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android FileProvider exposes DD share cache and transfer cache', () {
    final xml = File(
      'android/app/src/main/res/xml/dd_file_paths.xml',
    ).readAsStringSync();

    expect(xml, contains('name="dd_shared_files" path="dd_shared_files/"'));
    expect(xml, contains('name="dd_transfers" path="DD/transfers/"'));
  });

  test('Android video share uses local FileProvider flow after Dart download', () {
    final source = File(
      'lib/core/media/remote_media_action_service_io.dart',
    ).readAsStringSync();
    final shareVideoStart = source.indexOf('Future<String> shareVideo({');
    final copyVideoStart = source.indexOf('Future<String> copyVideo({');

    expect(shareVideoStart, greaterThanOrEqualTo(0));
    expect(copyVideoStart, greaterThan(shareVideoStart));

    final shareVideoSource = source.substring(shareVideoStart, copyVideoStart);
    expect(shareVideoSource, contains('_downloadTransferFile('));
    expect(shareVideoSource, contains("invokeMethod<bool>('shareLocalFile'"));
    expect(shareVideoSource, isNot(contains("invokeMethod<bool>('shareRemoteFile'")));
  });
}
