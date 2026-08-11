import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/media/media_cache_lease_registry.dart';
import 'media_api_client.dart';

final class ResumableDownloadHttpException extends HttpException {
  ResumableDownloadHttpException(this.statusCode, Uri uri)
    : super('媒体下载失败（HTTP $statusCode）。', uri: uri);

  final int statusCode;
}

final class ResumableDownloadResult {
  const ResumableDownloadResult({
    required this.path,
    required this.totalBytes,
    required this.resumedBytes,
  });

  final String path;
  final int totalBytes;
  final int resumedBytes;
}

final class ResumableMediaDownloader {
  ResumableMediaDownloader({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  Future<ResumableDownloadResult> download({
    required Future<Uri> Function() resolveUrl,
    required String destinationPath,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
    int maximumAttempts = 3,
  }) {
    return MediaCacheLeaseRegistry.shared.withLease(
      destinationPath,
      () => MediaCacheLeaseRegistry.shared.withLease(
        '$destinationPath.part',
        () => _downloadUnleased(
          resolveUrl: resolveUrl,
          destinationPath: destinationPath,
          expectedBytes: expectedBytes,
          cancellation: cancellation,
          onProgress: onProgress,
          maximumAttempts: maximumAttempts,
        ),
      ),
    );
  }

  Future<ResumableDownloadResult> _downloadUnleased({
    required Future<Uri> Function() resolveUrl,
    required String destinationPath,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
    int maximumAttempts = 3,
  }) async {
    if (destinationPath.trim().isEmpty) {
      throw const FormatException('下载目标路径不能为空。');
    }
    if (maximumAttempts < 1) {
      throw const FormatException('下载重试次数必须至少为 1。');
    }
    if (expectedBytes != null && expectedBytes < 0) {
      throw const FormatException('下载文件大小不能为负数。');
    }

    final target = File(destinationPath);
    final part = File('$destinationPath.part');
    await target.parent.create(recursive: true);

    if (await target.exists()) {
      final size = await target.length();
      if (expectedBytes == null || size == expectedBytes) {
        onProgress?.call(size, expectedBytes ?? size);
        return ResumableDownloadResult(
          path: target.path,
          totalBytes: size,
          resumedBytes: size,
        );
      }
      await target.delete();
    }

    Object? lastError;
    StackTrace? lastStackTrace;
    var initialResumedBytes = await _safeLength(part);
    if (cancellation?.isCancelled == true) {
      if (cancellation?.preservePartialOnCancel != true) {
        await _deleteIfExists(part);
      }
      throw const MediaDownloadCancelled();
    }

    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      final client = _clientFactory();
      void abort() => client.close();
      cancellation?.addAbortListener(abort);
      try {
        var existingBytes = await _safeLength(part);
        if (expectedBytes != null && existingBytes > expectedBytes) {
          await _truncate(part);
          existingBytes = 0;
          initialResumedBytes = 0;
        }

        final url = await resolveUrl();
        _throwIfCancelled(cancellation);
        final request = http.Request('GET', url);
        if (existingBytes > 0) {
          request.headers['Range'] = 'bytes=$existingBytes-';
        }
        final response = await client.send(request);
        _throwIfCancelled(cancellation);

        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
            existingBytes > 0 &&
            (expectedBytes == null || existingBytes == expectedBytes)) {
          await _commitPart(part, target);
          return ResumableDownloadResult(
            path: target.path,
            totalBytes: existingBytes,
            resumedBytes: initialResumedBytes,
          );
        }

        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          throw ResumableDownloadHttpException(response.statusCode, url);
        }

        var append = existingBytes > 0 &&
            response.statusCode == HttpStatus.partialContent;
        if (existingBytes > 0 && response.statusCode == HttpStatus.ok) {
          await _truncate(part);
          existingBytes = 0;
          append = false;
          initialResumedBytes = 0;
        }

        final responseTotal = _resolveTotalBytes(
          response,
          existingBytes: existingBytes,
          expectedBytes: expectedBytes,
        );
        if (expectedBytes != null &&
            responseTotal != null &&
            responseTotal != expectedBytes) {
          throw StateError(
            '下载文件大小不匹配：服务端 $responseTotal，预期 $expectedBytes。',
          );
        }

        final sink = part.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        var received = existingBytes;
        try {
          onProgress?.call(received, responseTotal ?? expectedBytes);
          await for (final chunk in response.stream) {
            _throwIfCancelled(cancellation);
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, responseTotal ?? expectedBytes);
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        _throwIfCancelled(cancellation);

        final actual = await part.length();
        final requiredTotal = expectedBytes ?? responseTotal;
        if (requiredTotal != null && actual != requiredTotal) {
          throw StateError(
            '下载未完成：已收到 $actual 字节，预期 $requiredTotal 字节。',
          );
        }

        await _commitPart(part, target);
        onProgress?.call(actual, requiredTotal ?? actual);
        return ResumableDownloadResult(
          path: target.path,
          totalBytes: actual,
          resumedBytes: initialResumedBytes,
        );
      } on MediaDownloadCancelled {
        if (cancellation?.preservePartialOnCancel != true) {
          await _deleteIfExists(part);
        }
        rethrow;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (cancellation?.isCancelled == true) {
          if (cancellation?.preservePartialOnCancel != true) {
            await _deleteIfExists(part);
          }
          throw const MediaDownloadCancelled();
        }
        if (attempt + 1 >= maximumAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      } finally {
        cancellation?.removeAbortListener(abort);
        client.close();
      }
    }

    Error.throwWithStackTrace(
      lastError ?? StateError('媒体下载失败。'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  int? _resolveTotalBytes(
    http.StreamedResponse response, {
    required int existingBytes,
    required int? expectedBytes,
  }) {
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final slash = contentRange.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < contentRange.length) {
        final totalText = contentRange.substring(slash + 1).trim();
        if (totalText != '*') {
          final total = int.tryParse(totalText);
          if (total != null && total >= 0) return total;
        }
      }
    }
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength >= 0) {
      return response.statusCode == HttpStatus.partialContent
          ? existingBytes + contentLength
          : contentLength;
    }
    return expectedBytes;
  }

  Future<int> _safeLength(File file) async =>
      await file.exists() ? file.length() : 0;

  Future<void> _truncate(File file) async {
    if (!await file.exists()) return;
    final randomAccess = await file.open(mode: FileMode.write);
    await randomAccess.truncate(0);
    await randomAccess.close();
  }

  Future<void> _commitPart(File part, File target) async {
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  void _throwIfCancelled(MediaDownloadCancellation? cancellation) {
    if (cancellation?.isCancelled == true) {
      throw const MediaDownloadCancelled();
    }
  }
}
