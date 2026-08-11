import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../features/messaging/data/media_api_client.dart';
import 'media_export_service.dart';

final class RemoteMediaActionService {
  Future<String> cacheFile({
    required Uri url,
    required String suggestedName,
    required String transferKey,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (cancellation?.isCancelled == true) throw const MediaDownloadCancelled();
    final response = await http.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('媒体下载失败（HTTP ${response.statusCode}）');
    }
    onProgress?.call(response.bodyBytes.length, response.bodyBytes.length);
    return url.toString();
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
    await Clipboard.setData(ClipboardData(text: url.toString()));
    return '当前浏览器限制直接打开远程文件，已复制临时下载链接';
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
    final response = await http.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('媒体下载失败（HTTP ${response.statusCode}）');
    }
    onProgress?.call(response.bodyBytes.length, response.bodyBytes.length);
    final name = MediaExportService.safeFileName(suggestedName);
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) throw const MediaExportCancelled();
    await XFile.fromData(
      response.bodyBytes,
      mimeType: mimeType,
      name: name,
    ).saveTo(location.path);
    return '已开始下载文件';
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
    await Clipboard.setData(ClipboardData(text: url.toString()));
    return '当前浏览器限制系统文件分享，已复制临时下载链接';
  }

  Future<String> saveVideo({
    required Uri url,
    required String mimeType,
    required String suggestedName,
    void Function(int received, int? total)? onProgress,
  }) async {
    final response = await http.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('媒体下载失败（HTTP ${response.statusCode}）');
    }
    onProgress?.call(response.bodyBytes.length, response.bodyBytes.length);
    final name = MediaExportService.safeFileName(suggestedName);
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) throw const MediaExportCancelled();
    await XFile.fromData(
      response.bodyBytes,
      mimeType: mimeType,
      name: name,
    ).saveTo(location.path);
    return '已开始下载视频';
  }

  Future<String> shareVideo({
    required Uri url,
    required String mimeType,
    required String suggestedName,
  }) async {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    return '当前浏览器限制系统视频分享，已复制临时下载链接';
  }

  Future<String> copyVideo({
    required Uri url,
    required String mimeType,
    required String suggestedName,
  }) async {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    return '当前浏览器限制复制视频文件，已复制临时下载链接';
  }
}
