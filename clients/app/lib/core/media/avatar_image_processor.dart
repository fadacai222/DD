import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const int maxAvatarSourceBytes = 64 * 1024 * 1024;
const int maxAvatarSourcePixels = 70 * 1000 * 1000;

final class AvatarCropSelection {
  const AvatarCropSelection({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.quarterTurns = 0,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final int quarterTurns;
}

final class AvatarCropPreview {
  const AvatarCropPreview({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

final class ProcessedAvatar {
  const ProcessedAvatar({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

Future<AvatarCropPreview> prepareAvatarCropPreview(Uint8List source) async {
  _validateSource(source);
  final result = await compute(_prepareCropPreview, source);
  if (result.bytes.isEmpty || result.width <= 0 || result.height <= 0) {
    throw const FormatException('无法解析这张图片。');
  }
  return result;
}

Future<ProcessedAvatar> processAvatarImage(
  Uint8List source, {
  AvatarCropSelection? crop,
}) async {
  _validateSource(source);
  final encoded = await compute(
    _compressAvatarToJpeg,
    _AvatarProcessRequest(source: source, crop: crop),
  );
  if (encoded.isEmpty) throw const FormatException('无法解析或裁剪这张图片。');
  return ProcessedAvatar(bytes: encoded, contentType: 'image/jpeg');
}

void _validateSource(Uint8List source) {
  if (source.isEmpty) throw const FormatException('图片文件为空。');
  if (source.length > maxAvatarSourceBytes) {
    throw const FormatException('源图片超过 64 MiB，为避免设备内存耗尽无法处理。');
  }
}

final class _AvatarProcessRequest {
  const _AvatarProcessRequest({required this.source, required this.crop});

  final Uint8List source;
  final AvatarCropSelection? crop;
}

AvatarCropPreview _prepareCropPreview(Uint8List source) {
  final decoded = _decodeOriented(source);
  if (decoded == null) {
    return AvatarCropPreview(bytes: Uint8List(0), width: 0, height: 0);
  }
  var preview = decoded;
  const previewMaxEdge = 2048;
  if (preview.width > previewMaxEdge || preview.height > previewMaxEdge) {
    final scale =
        previewMaxEdge /
        (preview.width > preview.height ? preview.width : preview.height);
    preview = img.copyResize(
      preview,
      width: (preview.width * scale).round().clamp(1, previewMaxEdge),
      height: (preview.height * scale).round().clamp(1, previewMaxEdge),
      interpolation: img.Interpolation.average,
    );
  }
  return AvatarCropPreview(
    bytes: Uint8List.fromList(img.encodeJpg(preview, quality: 92)),
    width: preview.width,
    height: preview.height,
  );
}

Uint8List _compressAvatarToJpeg(_AvatarProcessRequest request) {
  final decoded = _decodeOriented(request.source);
  if (decoded == null) return Uint8List(0);
  img.Image image = decoded;

  final crop = request.crop;
  if (crop != null) {
    final quarterTurns = crop.quarterTurns % 4;
    if (quarterTurns != 0) {
      image = img.copyRotate(image, angle: quarterTurns * 90);
    }
    final normalizedWidth = crop.width.clamp(0.02, 1.0);
    final normalizedHeight = crop.height.clamp(0.02, 1.0);
    final normalizedLeft = crop.left.clamp(0.0, 1.0 - normalizedWidth);
    final normalizedTop = crop.top.clamp(0.0, 1.0 - normalizedHeight);
    var cropWidth = (normalizedWidth * image.width).round().clamp(
      1,
      image.width,
    );
    var cropHeight = (normalizedHeight * image.height).round().clamp(
      1,
      image.height,
    );
    // The UI selection is square in pixels. Rounding or EXIF dimension changes
    // can leave a one-pixel mismatch, so normalize to the smaller side here.
    final squarePixels = cropWidth < cropHeight ? cropWidth : cropHeight;
    cropWidth = squarePixels;
    cropHeight = squarePixels;
    final left = (normalizedLeft * image.width).round().clamp(
      0,
      image.width - cropWidth,
    );
    final top = (normalizedTop * image.height).round().clamp(
      0,
      image.height - cropHeight,
    );
    image = img.copyCrop(
      image,
      x: left,
      y: top,
      width: cropWidth,
      height: cropHeight,
    );
  } else {
    final side = image.width < image.height ? image.width : image.height;
    image = img.copyCrop(
      image,
      x: (image.width - side) ~/ 2,
      y: (image.height - side) ~/ 2,
      width: side,
      height: side,
    );
  }

  const maxEdge = 1536;
  if (image.width > maxEdge || image.height > maxEdge) {
    image = img.copyResize(
      image,
      width: maxEdge,
      height: maxEdge,
      interpolation: img.Interpolation.average,
    );
  }

  const targetBytes = 1800 * 1024;
  var quality = 90;
  var encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  while (encoded.length > targetBytes && quality > 66) {
    quality -= 6;
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  while (encoded.length > targetBytes && image.width > 320) {
    final edge = (image.width * 0.82).round().clamp(320, maxEdge);
    image = img.copyResize(
      image,
      width: edge,
      height: edge,
      interpolation: img.Interpolation.average,
    );
    encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  return encoded.length <= 2 * 1024 * 1024 ? encoded : Uint8List(0);
}

img.Image? _decodeOriented(Uint8List source) {
  final decoder = img.findDecoderForData(source);
  final info = decoder?.startDecode(source);
  if (decoder == null || info == null) return null;
  if (info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxAvatarSourcePixels) {
    return null;
  }
  final decoded = decoder.decode(source);
  return decoded == null ? null : img.bakeOrientation(decoded);
}
