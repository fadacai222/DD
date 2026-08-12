import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS file and media services keep 500 MiB media path based', () {
    final picker = File(
      'ios/Runner/Services/FilePickerService.swift',
    ).readAsStringSync();
    final exporter = File(
      'ios/Runner/Services/MediaExportService.swift',
    ).readAsStringSync();
    final chat = File(
      'lib/features/messaging/presentation/text_chat_page.dart',
    ).readAsStringSync();
    final moments = File(
      'lib/features/moments/presentation/moment_publish_page.dart',
    ).readAsStringSync();

    expect(picker, contains('UIDocumentPickerViewController'));
    expect(picker, contains('PHPickerViewController'));
    expect(picker, contains('loadFileRepresentation'));
    expect(picker, contains('FileManager.default.copyItem'));
    expect(picker, isNot(contains('Data(contentsOf:')));
    expect(picker, isNot(contains('readAsBytes')));

    expect(exporter, contains('creationRequestForAssetFromVideo'));
    expect(exporter, contains('UIActivityViewController'));
    expect(exporter, contains('UIDocumentInteractionController'));
    expect(exporter, contains('setItemProviders'));
    expect(exporter, contains('NSItemProvider(contentsOf: file)'));
    expect(exporter, isNot(contains('Data(contentsOf:')));

    final videoStart = chat.indexOf('Future<void> _runVideoUpload(');
    final videoEnd = chat.indexOf('Uri _localPlaybackUri(', videoStart);
    expect(videoStart, greaterThanOrEqualTo(0));
    expect(videoEnd, greaterThan(videoStart));
    final videoUpload = chat.substring(videoStart, videoEnd);
    expect(videoUpload, contains('uploadStream('));
    expect(videoUpload, contains('streamFactory: file.openRead'));
    expect(videoUpload, isNot(contains('readAsBytes')));

    final fileStart = chat.indexOf('Future<void> _runFileUpload(');
    final fileEnd = chat.indexOf('String _fileMimeType(', fileStart);
    expect(fileStart, greaterThanOrEqualTo(0));
    expect(fileEnd, greaterThan(fileStart));
    final fileUpload = chat.substring(fileStart, fileEnd);
    expect(fileUpload, contains('uploadStream('));
    expect(fileUpload, contains('streamFactory: file.openRead'));
    expect(fileUpload, isNot(contains('readAsBytes')));

    expect(moments, contains('source: DdFilePickerSource.photos'));
    expect(moments, contains('streamFactory: video.file.openRead'));
  });
}
