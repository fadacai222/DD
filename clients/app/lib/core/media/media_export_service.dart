import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

abstract interface class MediaExporter {
  Future<String> saveImage({
    required Uint8List bytes,
    required String mimeType,
    required String suggestedName,
  });

  Future<String> copyImage(Uint8List bytes);
}

final class MediaExportCancelled implements Exception {
  const MediaExportCancelled();
}

final class MediaExportService implements MediaExporter {
  MediaExportService({TargetPlatform? platform})
    : _platform = platform ?? defaultTargetPlatform;

  static const MethodChannel _channel = MethodChannel('dd/media_export');
  final TargetPlatform _platform;

  @override
  Future<String> copyImage(Uint8List bytes) async {
    if (bytes.isEmpty) throw const FormatException('图片内容为空。');
    await Pasteboard.writeImage(bytes);
    return '图片已复制';
  }

  @override
  Future<String> saveImage({
    required Uint8List bytes,
    required String mimeType,
    required String suggestedName,
  }) async {
    if (bytes.isEmpty) throw const FormatException('图片内容为空。');
    final fileName = safeFileName(suggestedName);
    if (!kIsWeb && _platform == TargetPlatform.android) {
      final uri = await _channel.invokeMethod<String>('saveImageToGallery', {
        'bytes': bytes,
        'mimeType': mimeType,
        'fileName': fileName,
      });
      if (uri == null || uri.trim().isEmpty) {
        throw PlatformException(
          code: 'MEDIA_EXPORT_FAILED',
          message: 'Android 未返回保存结果。',
        );
      }
      return '已保存到系统相册';
    }

    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null) throw const MediaExportCancelled();
    await XFile.fromData(
      bytes,
      mimeType: mimeType,
      name: fileName,
    ).saveTo(location.path);
    return kIsWeb ? '已开始下载' : '图片已保存';
  }

  static String safeFileName(String raw) {
    var value = raw.trim().replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    value = value.replaceAll(RegExp(r'[ .]+$'), '');
    if (value.isEmpty || RegExp(r'^\.+$').hasMatch(value)) return 'DD-media';
    if (value.length > 120) value = value.substring(0, 120);
    return value;
  }
}
