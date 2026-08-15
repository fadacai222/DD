import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android large-file picker streams selected files instead of materializing bytes', () {
    final activity = File(
      'android/app/src/main/kotlin/org/openimx/client/MainActivity.kt',
    ).readAsStringSync();
    final picker = File('lib/core/media/dd_file_picker.dart').readAsStringSync();
    final chatPage = File(
      'lib/features/messaging/presentation/text_chat_page.dart',
    ).readAsStringSync();

    expect(activity, contains('"dd/file_picker"'));
    expect(activity, contains('Intent.ACTION_OPEN_DOCUMENT'));
    expect(activity, contains('ActivityResultContracts.PickVisualMedia'));
    expect(activity, contains('ActivityResultContracts.PickMultipleVisualMedia'));
    expect(activity, contains('if (source == "photos")'));
    expect(activity, contains('.createIntent(this, request)'));
    expect(activity, contains('startActivityForResult(intent, FILE_PICKER_REQUEST)'));
    expect(activity, contains('input.copyTo(output'));
    expect(activity, contains('Thread {'));
    expect(activity, isNot(contains('ByteArray(fileSize')));
    expect(picker, contains("MethodChannel('dd/file_picker')"));
    expect(picker, contains('ddOpenMediaFiles'));
    expect(chatPage, contains('media = await ddOpenMediaFiles('));
    expect(chatPage, contains('source: DdFilePickerSource.photos'));
    expect(chatPage, contains('maxBytes: 2 * 1024 * 1024 * 1024'));
  });
}
