import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

Future<void> generateIosAppIcons({
  required File sourceFile,
  required File contentsFile,
  required Directory outputDirectory,
}) async {
  final sourceBytes = await sourceFile.readAsBytes();
  final source = img.decodeImage(sourceBytes);
  if (source == null) {
    throw StateError('Unable to decode iOS app icon source: ${sourceFile.path}');
  }
  _validateSource(source, sourceFile.path);
  final manifest = jsonDecode(await contentsFile.readAsString());
  if (manifest is! Map<String, dynamic> || manifest['images'] is! List) {
    throw StateError('Invalid AppIcon Contents.json');
  }
  await outputDirectory.create(recursive: true);

  for (final raw in manifest['images'] as List<dynamic>) {
    if (raw is! Map<String, dynamic>) continue;
    final filename = raw['filename']?.toString().trim() ?? '';
    final size = raw['size']?.toString().trim() ?? '';
    final scale = raw['scale']?.toString().trim() ?? '';
    if (filename.isEmpty || size.isEmpty || scale.isEmpty) continue;
    final base = double.tryParse(size.split('x').first);
    final scaleValue = double.tryParse(scale.replaceAll('x', ''));
    if (base == null || scaleValue == null) {
      throw StateError('Invalid AppIcon size/scale for $filename');
    }
    final pixels = (base * scaleValue).round();
    final resized = img.copyResize(
      source,
      width: pixels,
      height: pixels,
      interpolation: img.Interpolation.cubic,
    );
    final opaque = img.Image(width: pixels, height: pixels, numChannels: 3);
    for (var y = 0; y < pixels; y++) {
      for (var x = 0; x < pixels; x++) {
        final pixel = resized.getPixel(x, y);
        opaque.setPixelRgb(x, y, pixel.r, pixel.g, pixel.b);
      }
    }
    await File('${outputDirectory.path}${Platform.pathSeparator}$filename')
        .writeAsBytes(img.encodePng(opaque), flush: true);
  }
}

void _validateSource(img.Image source, String sourcePath) {
  final minDimension = source.width < source.height
      ? source.width
      : source.height;
  // The legacy 0.86 safe-margin asset leaves about 7% white on each edge.
  // Four percent catches that regression without rejecting normal antialiasing.
  var insetThreshold = (minDimension * 0.04).ceil();
  if (insetThreshold < 2) insetThreshold = 2;
  if (insetThreshold * 2 >= minDimension) return;

  for (var inset = 0; inset < insetThreshold; inset++) {
    if (!_ringIsOpaqueWhite(source, inset)) return;
  }
  throw StateError(
    'iOS app icon source has a suspicious white inset: $sourcePath',
  );
}

bool _ringIsOpaqueWhite(img.Image source, int inset) {
  final left = inset;
  final top = inset;
  final right = source.width - inset - 1;
  final bottom = source.height - inset - 1;
  for (var x = left; x <= right; x++) {
    if (!_isOpaqueWhite(source.getPixel(x, top)) ||
        !_isOpaqueWhite(source.getPixel(x, bottom))) {
      return false;
    }
  }
  for (var y = top + 1; y < bottom; y++) {
    if (!_isOpaqueWhite(source.getPixel(left, y)) ||
        !_isOpaqueWhite(source.getPixel(right, y))) {
      return false;
    }
  }
  return true;
}

bool _isOpaqueWhite(img.Pixel pixel) =>
    pixel.a >= 250 && pixel.r >= 245 && pixel.g >= 245 && pixel.b >= 245;
