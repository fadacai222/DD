import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const int maxChatImageSourceBytes = 96 * 1024 * 1024;
const int maxChatImageSourcePixels = 90 * 1000 * 1000;
const int maxChatImageUploadBytes = 20 * 1024 * 1024;

final class ChatVisualMetadata {
  const ChatVisualMetadata({required this.width, required this.height});

  final int width;
  final int height;
}

Future<ChatVisualMetadata> inspectChatVisual(Uint8List source) async {
  if (source.isEmpty) throw const FormatException('媒体文件为空。');
  if (source.length > 50 * 1024 * 1024) {
    throw const FormatException('GIF 超过 50 MiB，暂时无法发送。');
  }
  final size = await compute(_inspectChatVisual, source);
  if (size.width <= 0 || size.height <= 0) {
    throw const FormatException('无法解析这张图片，或图片尺寸过大。');
  }
  return ChatVisualMetadata(width: size.width, height: size.height);
}

({int width, int height}) _inspectChatVisual(Uint8List source) {
  final decoder = img.findDecoderForData(source);
  final info = decoder?.startDecode(source);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxChatImageSourcePixels) {
    return (width: 0, height: 0);
  }
  return (width: info.width, height: info.height);
}

final class ProcessedChatImage {
  const ProcessedChatImage({
    required this.bytes,
    required this.contentType,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String contentType;
  final int width;
  final int height;
}

Future<ProcessedChatImage> processChatImage(Uint8List source) async {
  if (source.isEmpty) throw const FormatException('图片文件为空。');
  if (source.length > maxChatImageSourceBytes) {
    throw const FormatException('源图片超过 96 MiB，为避免设备内存耗尽无法处理。');
  }
  final result = await compute(_compressChatImageToJpeg, source);
  if (result.bytes.isEmpty || result.width <= 0 || result.height <= 0) {
    throw const FormatException('无法解析这张图片，或图片尺寸过大。');
  }
  if (result.bytes.length > maxChatImageUploadBytes) {
    throw const FormatException('图片处理后仍超过 20 MiB，暂时无法发送。');
  }
  return ProcessedChatImage(
    bytes: result.bytes,
    contentType: 'image/jpeg',
    width: result.width,
    height: result.height,
  );
}

({Uint8List bytes, int width, int height}) _compressChatImageToJpeg(
  Uint8List source,
) {
  final decoder = img.findDecoderForData(source);
  final info = decoder?.startDecode(source);
  if (decoder == null || info == null) {
    return (bytes: Uint8List(0), width: 0, height: 0);
  }
  if (info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxChatImageSourcePixels) {
    return (bytes: Uint8List(0), width: 0, height: 0);
  }
  final decoded = decoder.decode(source);
  if (decoded == null) {
    return (bytes: Uint8List(0), width: 0, height: 0);
  }
  var image = img.bakeOrientation(decoded);

  const maxEdge = 4096;
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

  var quality = 90;
  var encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  while (encoded.length > 12 * 1024 * 1024 && quality > 68) {
    quality -= 5;
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  while (encoded.length > maxChatImageUploadBytes &&
      image.width > 640 &&
      image.height > 640) {
    image = img.copyResize(
      image,
      width: (image.width * 0.85).round().clamp(1, maxEdge),
      height: (image.height * 0.85).round().clamp(1, maxEdge),
      interpolation: img.Interpolation.average,
    );
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  return (bytes: encoded, width: image.width, height: image.height);
}
