import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/media_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android image export writes through MediaStore channel', (
    tester,
  ) async {
    const channel = MethodChannel('dd/media_export');
    MethodCall? captured;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      captured = call;
      return 'content://media/external/images/media/42';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final result = await MediaExportService(platform: TargetPlatform.android)
        .saveImage(
          bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          mimeType: 'image/png',
          suggestedName: 'DD-avatar-alice.png',
        );

    expect(captured?.method, 'saveImageToGallery');
    expect(captured?.arguments, <String, Object>{
      'bytes': Uint8List.fromList(<int>[1, 2, 3, 4]),
      'mimeType': 'image/png',
      'fileName': 'DD-avatar-alice.png',
    });
    expect(result, contains('相册'));
  });

  test('normalizes unsafe suggested file names', () {
    expect(
      MediaExportService.safeFileName(' DD/avatar:*alice?.png '),
      'DD_avatar__alice_.png',
    );
    expect(MediaExportService.safeFileName('...'), 'DD-media');
  });
}
