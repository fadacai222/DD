import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/image_viewer_page.dart';
import 'package:im_client/core/media/media_export_service.dart';

void main() {
  testWidgets('Android media viewer hides copy but keeps save', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ImageViewerPage(
            bytes: Uint8List.fromList(<int>[1, 2, 3]),
            mimeType: 'image/png',
            suggestedName: 'photo.png',
            exporter: _FakeExporter(),
          ),
        ),
      );

      expect(find.byKey(const Key('media-viewer-copy')), findsNothing);
      expect(find.byKey(const Key('media-viewer-download')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('download button exports the currently displayed image', (
    tester,
  ) async {
    final exporter = _FakeExporter();
    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerPage(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          mimeType: 'image/png',
          suggestedName: 'DD-avatar-alice.png',
          exporter: exporter,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('media-viewer-download')));
    await tester.pumpAndSettle();

    expect(exporter.calls, 1);
    expect(exporter.mimeType, 'image/png');
    expect(exporter.suggestedName, 'DD-avatar-alice.png');
    expect(find.text('已保存到系统相册'), findsOneWidget);
  });
}

final class _FakeExporter implements MediaExporter {
  int calls = 0;
  int copyCalls = 0;
  String mimeType = '';
  String suggestedName = '';

  @override
  Future<String> copyImage(Uint8List bytes) async {
    copyCalls++;
    return '图片已复制';
  }

  @override
  Future<String> saveImage({
    required Uint8List bytes,
    required String mimeType,
    required String suggestedName,
  }) async {
    calls++;
    this.mimeType = mimeType;
    this.suggestedName = suggestedName;
    return '已保存到系统相册';
  }
}
