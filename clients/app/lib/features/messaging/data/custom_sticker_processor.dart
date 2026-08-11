import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;

import 'media_api_client.dart';

const int maxCustomStickerSourceBytes = 64 * 1024 * 1024;
const int maxCustomStickerPixels = 64 * 1024 * 1024;
const int maxCustomStickerDimension = 16384;
const int targetCustomStickerDimension = 512;

final class PreparedCustomSticker {
  const PreparedCustomSticker({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.streamFactory,
    required this.animated,
  });

  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int width;
  final int height;
  final Stream<List<int>> Function() streamFactory;
  final bool animated;
}

Future<PreparedCustomSticker> prepareCustomSticker(
  XFile file, {
  MediaUploadCancellation? cancellation,
  void Function(int processedBytes, int totalBytes)? onProgress,
}) async {
  final size = await file.length();
  if (size <= 0) throw const FormatException('表情文件为空。');
  if (size > maxCustomStickerSourceBytes) {
    throw const FormatException('源表情超过 64 MiB，为避免内存或磁盘资源耗尽无法处理。');
  }
  _throwIfCancelled(cancellation);

  final lower = file.name.toLowerCase();
  if (lower.endsWith('.gif')) {
    final prefix = await _readPrefix(file, 16);
    final dimensions = _gifDimensions(prefix);
    _validateDimensions(dimensions.$1, dimensions.$2);
    return PreparedCustomSticker(
      fileName: file.name.isEmpty ? 'custom-sticker.gif' : file.name,
      mimeType: 'image/gif',
      sizeBytes: size,
      width: dimensions.$1,
      height: dimensions.$2,
      animated: true,
      streamFactory: () => _progressStream(
        file.openRead(),
        size,
        cancellation,
        onProgress,
      ),
    );
  }

  final source = BytesBuilder(copy: false);
  var read = 0;
  await for (final chunk in file.openRead()) {
    _throwIfCancelled(cancellation);
    source.add(chunk);
    read += chunk.length;
    onProgress?.call(read, size);
  }
  _throwIfCancelled(cancellation);
  final sourceBytes = source.takeBytes();
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw const FormatException('只支持 PNG、JPG、WebP 或 GIF 表情。');
  }
  final oriented = img.bakeOrientation(decoded);
  _validateDimensions(oriented.width, oriented.height);
  _throwIfCancelled(cancellation);

  var output = oriented;
  final longest = output.width > output.height ? output.width : output.height;
  if (longest > targetCustomStickerDimension) {
    if (output.width >= output.height) {
      output = img.copyResize(
        output,
        width: targetCustomStickerDimension,
        interpolation: img.Interpolation.average,
      );
    } else {
      output = img.copyResize(
        output,
        height: targetCustomStickerDimension,
        interpolation: img.Interpolation.average,
      );
    }
  }
  _throwIfCancelled(cancellation);

  final png = Uint8List.fromList(img.encodePng(output, level: 8));
  if (png.isEmpty || png.length > maxCustomStickerSourceBytes) {
    throw const FormatException('表情压缩结果异常，请更换图片。');
  }
  onProgress?.call(size, size);
  return PreparedCustomSticker(
    fileName: 'custom-sticker.png',
    mimeType: 'image/png',
    sizeBytes: png.length,
    width: output.width,
    height: output.height,
    animated: false,
    streamFactory: () => Stream<List<int>>.value(png),
  );
}

Stream<List<int>> _progressStream(
  Stream<List<int>> source,
  int total,
  MediaUploadCancellation? cancellation,
  void Function(int processedBytes, int totalBytes)? onProgress,
) async* {
  var sent = 0;
  await for (final chunk in source) {
    _throwIfCancelled(cancellation);
    sent += chunk.length;
    onProgress?.call(sent, total);
    yield chunk;
  }
  _throwIfCancelled(cancellation);
}

Future<Uint8List> _readPrefix(XFile file, int count) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    final remaining = count - bytes.length;
    if (remaining <= 0) break;
    bytes.add(chunk.length <= remaining ? chunk : chunk.sublist(0, remaining));
    if (bytes.length >= count) break;
  }
  return bytes.takeBytes();
}

(int, int) _gifDimensions(Uint8List bytes) {
  if (bytes.length < 10) throw const FormatException('GIF 文件头不完整。');
  final signature = String.fromCharCodes(bytes.sublist(0, 6));
  if (signature != 'GIF87a' && signature != 'GIF89a') {
    throw const FormatException('GIF 文件格式无效。');
  }
  final width = bytes[6] | (bytes[7] << 8);
  final height = bytes[8] | (bytes[9] << 8);
  return (width, height);
}

void _validateDimensions(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw const FormatException('表情图片尺寸无效。');
  }
  if (width > maxCustomStickerDimension ||
      height > maxCustomStickerDimension ||
      width * height > maxCustomStickerPixels) {
    throw const FormatException('表情分辨率过高，为避免内存耗尽无法处理。');
  }
}

void _throwIfCancelled(MediaUploadCancellation? cancellation) {
  if (cancellation?.isCancelled == true) {
    throw const MediaUploadCancelled();
  }
}
