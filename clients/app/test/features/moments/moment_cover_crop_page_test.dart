import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/moments/presentation/moment_cover_crop_page.dart';
import 'package:image/image.dart' as img;

void main() {
  test('cover processor outputs bounded 16:9 jpeg around focal point', () async {
    final source = img.Image(width: 1600, height: 1200);
    img.fill(source, color: img.ColorRgb8(40, 120, 200));
    final bytes = Uint8List.fromList(img.encodeJpg(source, quality: 92));

    final output = await processMomentCoverImage(
      bytes,
      const MomentCoverCropResult(focalX: 0.8, focalY: 0.3),
    );
    final decoded = img.decodeImage(output);

    expect(decoded, isNotNull);
    expect(decoded!.width / decoded.height, closeTo(16 / 9, 0.01));
    expect(decoded.width, lessThanOrEqualTo(1920));
    expect(output.length, lessThanOrEqualTo(2 * 1024 * 1024));
  });

  test('cover processor rejects empty source', () async {
    await expectLater(
      processMomentCoverImage(
        Uint8List(0),
        const MomentCoverCropResult(focalX: 0.5, focalY: 0.5),
      ),
      throwsFormatException,
    );
  });
}
