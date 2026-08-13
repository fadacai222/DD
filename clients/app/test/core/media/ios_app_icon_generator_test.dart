import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import '../../../tool/ios_app_icon_generator.dart';

void main() {
  test('rejects a canonical source with a 0.86 white inset', () async {
    final root = await Directory.systemTemp.createTemp('dd-ios-icon-inset-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = img.Image(width: 100, height: 100, numChannels: 3)
      ..clear(img.ColorRgb8(255, 255, 255));
    for (var y = 7; y < 93; y++) {
      for (var x = 7; x < 93; x++) {
        source.setPixelRgb(x, y, 24, 190, 128);
      }
    }
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
          ],
        }),
      );

    expect(
      () => generateIosAppIcons(
        sourceFile: sourceFile,
        contentsFile: contentsFile,
        outputDirectory: Directory('${root.path}/out'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('inset'),
        ),
      ),
    );
  });

  test('brand pipeline keeps iOS full bleed without changing other platforms', () {
    final wrapper = File('tool/generate_ios_app_icons.dart').readAsStringSync();
    expect(wrapper, contains('../../设计图/brand-assets/DD-logo-master.png'));
    expect(wrapper, isNot(contains('DD-icon-1024.png')));

    final script = File('../../scripts/generate-brand-assets.ps1').readAsStringSync();
    expect(
      script,
      contains(
        "DD-icon-1024.png') -Size 1024 -Scale 1.00 -Background ([System.Drawing.Color]::White)",
      ),
    );
    expect(
      script,
      contains("ic_launcher.png') -Size \$entry.Value -Scale 0.82"),
    );
    expect(
      script,
      contains("ic_launcher_round.png') -Size \$entry.Value -Scale 0.80"),
    );
    expect(
      script,
      contains("Icon-512.png') -Size 512 -Scale 0.86"),
    );
    expect(script, contains('New-PngIco -Source \$source -Path \$windowsIco'));
  });

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

  test('repository AppIcon manifest generates every declared opaque size', () async {
    final root = await Directory.systemTemp.createTemp('dd-ios-icon-manifest-test-');
    addTearDown(() => root.delete(recursive: true));
    final contentsFile = File(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
    );
    final manifest = jsonDecode(await contentsFile.readAsString()) as Map<String, dynamic>;
    final entries = (manifest['images'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .where((entry) => (entry['filename']?.toString() ?? '').isNotEmpty)
        .toList(growable: false);
    final output = Directory('${root.path}/out');

    await generateIosAppIcons(
      sourceFile: File('../../设计图/brand-assets/DD-logo-master.png'),
      contentsFile: contentsFile,
      outputDirectory: output,
    );

    final uniqueFilenames = entries
        .map((entry) => entry['filename']!.toString())
        .toSet();
    expect(output.listSync().whereType<File>(), hasLength(uniqueFilenames.length));
    for (final entry in entries) {
      final filename = entry['filename']!.toString();
      final base = double.parse(entry['size'].toString().split('x').first);
      final scale = double.parse(entry['scale'].toString().replaceAll('x', ''));
      final pixels = (base * scale).round();
      final generated = img.decodePng(
        await File('${output.path}${Platform.pathSeparator}$filename').readAsBytes(),
      );
      expect(generated, isNotNull, reason: filename);
      expect(generated!.width, pixels, reason: filename);
      expect(generated.height, pixels, reason: filename);
      expect(generated.numChannels, 3, reason: '$filename must be opaque RGB');
    }
  });
}
