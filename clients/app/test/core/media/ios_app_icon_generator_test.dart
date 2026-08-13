import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import '../../../tool/ios_app_icon_generator.dart';

void main() {
  test('generates opaque iOS icon sizes from canonical source', () async {
    final root = await Directory.systemTemp.createTemp('dd-ios-icon-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = img.Image(width: 64, height: 64, numChannels: 4)
      ..clear(img.ColorRgba8(12, 34, 56, 128));
    final sourceFile = File('${root.path}/source.png')
      ..writeAsBytesSync(img.encodePng(source));
    final contentsFile = File('${root.path}/Contents.json')
      ..writeAsStringSync(
        jsonEncode({
          'images': [
            {
              'size': '20x20',
              'scale': '2x',
              'filename': 'Icon-40.png',
            },
            {
              'size': '1024x1024',
              'scale': '1x',
              'filename': 'Icon-1024.png',
            },
          ],
        }),
      );
    final output = Directory('${root.path}/out');

    await generateIosAppIcons(
      sourceFile: sourceFile,
      contentsFile: contentsFile,
      outputDirectory: output,
    );

    final icon40 = img.decodePng(await File('${output.path}/Icon-40.png').readAsBytes());
    final icon1024 = img.decodePng(
      await File('${output.path}/Icon-1024.png').readAsBytes(),
    );
    expect(icon40, isNotNull);
    expect(icon40!.width, 40);
    expect(icon40.height, 40);
    expect(icon40.numChannels, 3);
    expect(icon1024, isNotNull);
    expect(icon1024!.width, 1024);
    expect(icon1024.height, 1024);
    expect(icon1024.numChannels, 3);
  });
}
