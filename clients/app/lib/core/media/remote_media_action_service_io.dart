import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

import 'media_export_service.dart';

final class RemoteMediaActionService {
  RemoteMediaActionService({TargetPlatform? platform})
    : _platform = platform ?? defaultTargetPlatform;

  static const MethodChannel _channel = MethodChannel('dd/media_export');
  final TargetPlatform _platform;

  Future<String> saveVideo({
    required Uri url,
    required String mimeType,
    required String suggestedName,
    void Function(int received, int? total)? onProgress,
  }) async {
    final fileName = MediaExportService.safeFileName(suggestedName);
    if (_platform == TargetPlatform.android) {
      final uri = await _channel.invokeMethod<String>(
        'saveRemoteVideoToGallery',
        {'url': url.toString(), 'mimeType': mimeType, 'fileName': fileName},
      );
      if (uri == null || uri.trim().isEmpty) {
        throw PlatformException(
          code: 'MEDIA_EXPORT_FAILED',
          message: 'Android 未返回视频保存结果。',
        );
      }
      return '视频已保存到系统相册';
    }

    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null) throw const MediaExportCancelled();
    await _downloadToFile(url, File(location.path), onProgress: onProgress);
    return '视频已保存';
  }

  Future<String> copyVideo({
    required Uri url,
    required String mimeType,
    required String suggestedName,
  }) async {
    final fileName = MediaExportService.safeFileName(suggestedName);
    if (_platform == TargetPlatform.android) {
      final copied = await _channel.invokeMethod<bool>(
        'copyRemoteFileToClipboard',
        {'url': url.toString(), 'mimeType': mimeType, 'fileName': fileName},
      );
      if (copied != true) {
        throw PlatformException(
          code: 'MEDIA_COPY_FAILED',
          message: 'Android 视频复制失败。',
        );
      }
      return '视频已复制';
    }

    final root = await getTemporaryDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}DD${Platform.pathSeparator}clipboard',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    await _cleanupClipboardDirectory(directory);
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await _downloadToFile(url, file);
    await Pasteboard.writeFiles(<String>[file.path]);
    return '视频已复制';
  }

  Future<void> _downloadToFile(
    Uri url,
    File file, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', url);
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('媒体下载失败（HTTP ${response.statusCode}）');
      }
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      sink = file.openWrite();
      var received = 0;
      final total = response.contentLength;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> _cleanupClipboardDirectory(Directory directory) async {
    try {
      final now = DateTime.now();
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) > const Duration(days: 1)) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Cache cleanup is best effort.
    }
  }
}
