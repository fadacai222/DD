import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const int maxChatWallpaperSourceBytes = 64 * 1024 * 1024;
const int maxChatWallpaperSourcePixels = 70 * 1000 * 1000;

Future<Uint8List> processChatWallpaper(Uint8List source) async {
  if (source.isEmpty) throw const FormatException('背景图片为空。');
  if (source.length > maxChatWallpaperSourceBytes) {
    throw const FormatException('背景原图超过 64 MiB，为避免内存占用过高无法处理。');
  }
  final output = await compute(_processChatWallpaper, source);
  if (output.isEmpty) throw const FormatException('无法解析这张背景图片。');
  return output;
}

Uint8List _processChatWallpaper(Uint8List source) {
  final decoder = img.findDecoderForData(source);
  final info = decoder?.startDecode(source);
  if (decoder == null ||
      info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxChatWallpaperSourcePixels) {
    return Uint8List(0);
  }
  final decoded = decoder.decode(source);
  if (decoded == null) return Uint8List(0);
  var image = img.bakeOrientation(decoded);
  const maxEdge = 1920;
  final longEdge = image.width > image.height ? image.width : image.height;
  if (longEdge > maxEdge) {
    final scale = maxEdge / longEdge;
    image = img.copyResize(
      image,
      width: (image.width * scale).round().clamp(1, maxEdge),
      height: (image.height * scale).round().clamp(1, maxEdge),
      interpolation: img.Interpolation.average,
    );
  }
  var quality = 86;
  var encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  while (encoded.length > 2 * 1024 * 1024 && quality > 66) {
    quality -= 5;
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }
  return encoded;
}
