import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/messaging/data/media_api_client.dart';
import '../../features/messaging/data/resumable_media_downloader.dart';
import 'media_cache_manager_backend_io.dart' show pruneManagedMediaCache;
import 'media_export_service.dart';

final class RemoteMediaActionService {
  RemoteMediaActionService({
    TargetPlatform? platform,
    ResumableMediaDownloader? downloader,
  }) : _platform = platform ?? defaultTargetPlatform,
       _downloader = downloader ?? ResumableMediaDownloader();

  static const MethodChannel _channel = MethodChannel('dd/media_export');
  final TargetPlatform _platform;
  final ResumableMediaDownloader _downloader;

  Future<String> cacheFile({
    required Uri url,
    required String suggestedName,
    required String transferKey,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final file = await _downloadTransferFile(
      url: url,
      transferKey: transferKey,
      fileName: MediaExportService.safeFileName(suggestedName),
      expectedBytes: expectedBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    return file.path;
  }

  Future<String> openFile({
    required Uri url,
    required String mimeType,
    required String suggestedName,
    required String transferKey,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final fileName = MediaExportService.safeFileName(suggestedName);
    final file = await _downloadTransferFile(
      url: url,
      transferKey: transferKey,
      fileName: fileName,
      expectedBytes: expectedBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    if (_platform == TargetPlatform.android) {
      final opened = await _channel.invokeMethod<bool>('openLocalFile', {
        'path': file.path,
        'mimeType': mimeType,
        'fileName': fileName,
      });
      if (opened != true) {
        throw PlatformException(
          code: 'MEDIA_OPEN_FAILED',
          message: 'Android 文件打开失败。',
        );
      }
      return '已交给系统应用打开';
    }
    if (_platform == TargetPlatform.macOS) {
      await Process.start('open', [file.path]);
    } else if (_platform == TargetPlatform.linux) {
      await Process.start('xdg-open', [file.path]);
    } else if (_platform == TargetPlatform.windows) {
      await Process.start(file.path, const [], runInShell: true);
    } else {
      throw UnsupportedError('当前平台暂不支持直接打开文件。');
    }
    return '已交给系统应用打开';
  }

  Future<String> saveFile({
    required Uri url,
    required String mimeType,
    required String suggestedName,
    required String transferKey,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final fileName = MediaExportService.safeFileName(suggestedName);
    final location = _platform == TargetPlatform.android
        ? null
        : await getSaveLocation(suggestedName: fileName);
    if (_platform != TargetPlatform.android && location == null) {
      throw const MediaExportCancelled();
    }
    final file = await _downloadTransferFile(
      url: url,
      transferKey: transferKey,
      fileName: fileName,
      expectedBytes: expectedBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    if (_platform == TargetPlatform.android) {
      final uri = await _channel.invokeMethod<String>('saveLocalFileToDownloads', {
        'path': file.path,
        'mimeType': mimeType,
        'fileName': fileName,
      });
      if (uri == null || uri.trim().isEmpty) {
        throw PlatformException(
          code: 'MEDIA_EXPORT_FAILED',
          message: 'Android 未返回文件保存结果。',
        );
      }
      return '文件已保存到下载目录';
    }
    await file.copy(location!.path);
    return '文件已保存';
  }

  Future<String> shareFile({
    required Uri url,
    required String mimeType,
    required String suggestedName,
    required String transferKey,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final fileName = MediaExportService.safeFileName(suggestedName);
    final file = await _downloadTransferFile(
      url: url,
      transferKey: transferKey,
      fileName: fileName,
      expectedBytes: expectedBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    if (_platform == TargetPlatform.android) {
      final shared = await _channel.invokeMethod<bool>('shareLocalFile', {
        'path': file.path,
        'mimeType': mimeType,
        'fileName': fileName,
      });
      if (shared != true) {
        throw PlatformException(
          code: 'MEDIA_SHARE_FAILED',
          message: 'Android 文件分享失败。',
        );
      }
      return '已打开系统分享';
    }
    await Pasteboard.writeFiles(<String>[file.path]);
    return '当前桌面端已复制文件，可直接粘贴到支持文件的应用';
  }

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

  Future<String> shareVideo({
    required Uri url,
    required String mimeType,
    required String suggestedName,
  }) async {
    final fileName = MediaExportService.safeFileName(suggestedName);
    final file = url.scheme == 'file'
        ? File(url.toFilePath())
        : await _downloadTransferFile(
            url: url,
            transferKey: 'video-share-${url.hashCode}',
            fileName: fileName,
            expectedBytes: null,
            cancellation: null,
            onProgress: null,
          );
    if (!await file.exists()) {
      throw FileSystemException('待分享的视频文件不存在。', file.path);
    }
    if (_platform == TargetPlatform.android) {
      final shared = await _channel.invokeMethod<bool>('shareLocalFile', {
        'path': file.path,
        'mimeType': mimeType,
        'fileName': fileName,
      });
      if (shared != true) {
        throw PlatformException(
          code: 'MEDIA_SHARE_FAILED',
          message: 'Android 视频分享失败。',
        );
      }
      return '已打开系统分享';
    }
    await Pasteboard.writeFiles(<String>[file.path]);
    return '视频文件已复制，可粘贴到支持文件的应用';
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

  Future<File> _downloadTransferFile({
    required Uri url,
    required String transferKey,
    required String fileName,
    required int? expectedBytes,
    required MediaDownloadCancellation? cancellation,
    required void Function(int received, int? total)? onProgress,
  }) async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}DD${Platform.pathSeparator}transfers',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    final safeKey = MediaExportService.safeFileName(transferKey);
    final target = File(
      '${directory.path}${Platform.pathSeparator}$safeKey-$fileName',
    );
    final result = await _downloader.download(
      resolveUrl: () async => url,
      destinationPath: target.path,
      expectedBytes: expectedBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    await pruneManagedMediaCache();
    return File(result.path);
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
