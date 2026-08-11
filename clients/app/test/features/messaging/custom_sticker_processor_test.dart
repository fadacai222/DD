import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:im_client/features/messaging/data/custom_sticker_processor.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';

void main() {
  test('static sticker is resized and encoded as transparent-safe PNG', () async {
    final source = img.Image(width: 1400, height: 700, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(80, 160, 220, 120));
    final file = XFile.fromData(
      Uint8List.fromList(img.encodePng(source)),
      name: 'large.png',
      mimeType: 'image/png',
    );

    final prepared = await prepareCustomSticker(file);
    final output = BytesBuilder(copy: false);
    await for (final chunk in prepared.streamFactory()) {
      output.add(chunk);
    }
    final decoded = img.decodePng(output.takeBytes());

    expect(prepared.animated, isFalse);
    expect(prepared.mimeType, 'image/png');
    expect(prepared.width, 512);
    expect(prepared.height, 256);
    expect(decoded, isNotNull);
    expect(decoded!.numChannels, greaterThanOrEqualTo(4));
  });

  test('animated GIF keeps original byte stream and animation semantics', () async {
    final gif = Uint8List.fromList(<int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
      0x02, 0x00, 0x03, 0x00,
      0x80, 0x00, 0x00,
    ]);
    final file = XFile.fromData(gif, name: 'animated.gif', mimeType: 'image/gif');

    final prepared = await prepareCustomSticker(file);
    final output = BytesBuilder(copy: false);
    await for (final chunk in prepared.streamFactory()) {
      output.add(chunk);
    }

    expect(prepared.animated, isTrue);
    expect(prepared.mimeType, 'image/gif');
    expect(prepared.width, 2);
    expect(prepared.height, 3);
    expect(output.takeBytes(), gif);
  });

  test('cancellation stops preparation before upload', () async {
    final cancellation = MediaUploadCancellation()..cancel();
    final file = XFile.fromData(
      Uint8List.fromList(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0]),
      name: 'cancel.gif',
      mimeType: 'image/gif',
    );

    await expectLater(
      prepareCustomSticker(file, cancellation: cancellation),
      throwsA(isA<MediaUploadCancelled>()),
    );
  });
}
