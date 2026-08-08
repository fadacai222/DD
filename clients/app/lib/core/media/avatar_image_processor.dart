import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const int maxAvatarSourceBytes = 64 * 1024 * 1024;
const int maxAvatarSourcePixels = 70 * 1000 * 1000;

final class ProcessedAvatar {
  const ProcessedAvatar({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

Future<ProcessedAvatar> processAvatarImage(Uint8List source) async {
  if (source.isEmpty) throw const FormatException('图片文件为空。');
  if (source.length > maxAvatarSourceBytes) {
    throw const FormatException('源图片超过 64 MiB，为避免设备内存耗尽无法处理。');
  }
  final encoded = await compute(_compressAvatarToJpeg, source);
  if (encoded.isEmpty) throw const FormatException('无法解析这张图片。');
  return ProcessedAvatar(bytes: encoded, contentType: 'image/jpeg');
}

Uint8List _compressAvatarToJpeg(Uint8List source) {
  final decoder = img.findDecoderForData(source);
  final info = decoder?.startDecode(source);
  if (decoder == null || info == null) return Uint8List(0);
  if (info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxAvatarSourcePixels) {
    return Uint8List(0);
  }
  final decoded = decoder.decode(source);
  if (decoded == null) return Uint8List(0);
  var image = img.bakeOrientation(decoded);

  const maxEdge = 1536;
  if (image.width > maxEdge || image.height > maxEdge) {
    final scale =
        maxEdge / (image.width > image.height ? image.width : image.height);
    image = img.copyResize(
      image,
      width: (image.width * scale).round().clamp(1, maxEdge),
      height: (image.height * scale).round().clamp(1, maxEdge),
      interpolation: img.Interpolation.average,
    );
  }

  const targetBytes = 1800 * 1024;
  var quality = 88;
  var encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  while (encoded.length > targetBytes && quality > 64) {
    quality -= 6;
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  while (encoded.length > targetBytes &&
      image.width > 320 &&
      image.height > 320) {
    image = img.copyResize(
      image,
      width: (image.width * 0.82).round().clamp(1, maxEdge),
      height: (image.height * 0.82).round().clamp(1, maxEdge),
      interpolation: img.Interpolation.average,
    );
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  return encoded.length <= 2 * 1024 * 1024 ? encoded : Uint8List(0);
}
