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
  });
}
