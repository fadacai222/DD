import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/avatar_image_processor.dart';
import 'package:image/image.dart' as img;

void main() {
  test('large source avatar is resized and compressed before upload', () async {
    final source = img.Image(width: 2400, height: 1800);
    img.fill(source, color: img.ColorRgb8(32, 180, 96));
    final sourceBytes = img.encodePng(source);

    final processed = await processAvatarImage(sourceBytes);
    final decoded = img.decodeImage(processed.bytes);

    expect(processed.contentType, 'image/jpeg');
    expect(processed.bytes.length, lessThanOrEqualTo(2 * 1024 * 1024));
    expect(decoded, isNotNull);
    expect(decoded!.width, lessThanOrEqualTo(1536));
    expect(decoded.height, lessThanOrEqualTo(1536));
    expect(decoded.width, decoded.height);
  });

  test('out-of-range crop coordinates are clamped to a valid square', () async {
    final source = img.Image(width: 400, height: 200);
    img.fillRect(
      source,
      x1: 0,
      y1: 0,
      x2: 199,
      y2: 199,
      color: img.ColorRgb8(230, 30, 30),
    );
    img.fillRect(
      source,
      x1: 200,
      y1: 0,
      x2: 399,
      y2: 199,
      color: img.ColorRgb8(25, 45, 225),
    );

    final processed = await processAvatarImage(
      img.encodePng(source),
      crop: const AvatarCropSelection(
        left: 99,
        top: -10,
        width: 0.5,
        height: 1,
      ),
    );
    final decoded = img.decodeJpg(processed.bytes)!;
    final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);

    expect(decoded.width, decoded.height);
    expect(decoded.width, greaterThan(0));
    expect(center.b, greaterThan(center.r));
  });

  test(
    'quarter-turn crop uses the same oriented coordinate space as UI',
    () async {
      final source = img.Image(width: 200, height: 100);
      img.fillRect(
        source,
        x1: 0,
        y1: 0,
        x2: 99,
        y2: 99,
        color: img.ColorRgb8(230, 30, 30),
      );
      img.fillRect(
        source,
        x1: 100,
        y1: 0,
        x2: 199,
        y2: 99,
        color: img.ColorRgb8(25, 45, 225),
      );

      // 90° clockwise makes the blue half the lower half of the oriented image.
      final processed = await processAvatarImage(
        img.encodePng(source),
        crop: const AvatarCropSelection(
          left: 0,
          top: 0.5,
          width: 1,
          height: 0.5,
          quarterTurns: 1,
        ),
      );
      final decoded = img.decodeJpg(processed.bytes)!;
      final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);

      expect(decoded.width, decoded.height);
      expect(center.b, greaterThan(center.r));
    },
  );

  test('manual crop selection is applied before avatar compression', () async {
    final source = img.Image(width: 200, height: 100);
    img.fillRect(
      source,
      x1: 0,
      y1: 0,
      x2: 99,
      y2: 99,
      color: img.ColorRgb8(230, 30, 30),
    );
    img.fillRect(
      source,
      x1: 100,
      y1: 0,
      x2: 199,
      y2: 99,
      color: img.ColorRgb8(25, 45, 225),
    );

    final processed = await processAvatarImage(
      img.encodePng(source),
      crop: const AvatarCropSelection(left: 0.5, top: 0, width: 0.5, height: 1),
    );
    final decoded = img.decodeJpg(processed.bytes)!;
    final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);

    expect(decoded.width, decoded.height);
    expect(center.b, greaterThan(center.r));
  });
}
