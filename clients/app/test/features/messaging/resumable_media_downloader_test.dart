import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/core/media/media_cache_lease_registry.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';
import 'package:im_client/features/messaging/data/resumable_media_downloader.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dd-resumable-download-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('resumes an existing part file with HTTP Range and commits atomically', () async {
    final target = File('${directory.path}${Platform.pathSeparator}video.mp4');
    final part = File('${target.path}.part');
    await part.writeAsBytes(<int>[0, 1, 2, 3]);
    String? range;
    final progress = <int>[];
    final downloader = ResumableMediaDownloader(
      clientFactory: () => MockClient((request) async {
        range = request.headers['range'];
        return http.Response.bytes(
          <int>[4, 5, 6, 7, 8, 9],
          HttpStatus.partialContent,
          headers: {
            'content-range': 'bytes 4-9/10',
            'content-length': '6',
          },
        );
      }),
    );

    final result = await downloader.download(
      resolveUrl: () async => Uri.parse('https://storage.invalid/video.mp4'),
      destinationPath: target.path,
      expectedBytes: 10,
      onProgress: (received, _) => progress.add(received),
    );

    expect(range, 'bytes=4-');
    expect(result.resumedBytes, 4);
    expect(result.totalBytes, 10);
    expect(await target.readAsBytes(), <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(await part.exists(), isFalse);
    expect(progress.first, 4);
    expect(progress.last, 10);
  });

  test('server ignoring Range safely restarts from byte zero', () async {
    final target = File('${directory.path}${Platform.pathSeparator}file.bin');
    final part = File('${target.path}.part');
    await part.writeAsBytes(<int>[9, 9, 9]);
    final downloader = ResumableMediaDownloader(
      clientFactory: () => MockClient((request) async {
        expect(request.headers['range'], 'bytes=3-');
        return http.Response.bytes(
          <int>[1, 2, 3, 4],
          HttpStatus.ok,
          headers: {'content-length': '4'},
        );
      }),
    );

    final result = await downloader.download(
      resolveUrl: () async => Uri.parse('https://storage.invalid/file.bin'),
      destinationPath: target.path,
      expectedBytes: 4,
    );

    expect(result.resumedBytes, 0);
    expect(await target.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('explicit cancellation deletes partial data by default', () async {
    final target = File('${directory.path}${Platform.pathSeparator}cancel.bin');
    final part = File('${target.path}.part');
    await part.writeAsBytes(<int>[1, 2, 3]);
    final cancellation = MediaDownloadCancellation()..cancel();
    final downloader = ResumableMediaDownloader();

    await expectLater(
      downloader.download(
        resolveUrl: () async => Uri.parse('https://storage.invalid/cancel.bin'),
        destinationPath: target.path,
        expectedBytes: 10,
        cancellation: cancellation,
      ),
      throwsA(isA<MediaDownloadCancelled>()),
    );

    expect(await part.exists(), isFalse);
    expect(await target.exists(), isFalse);
  });

  test('active download leases final and partial cache paths', () async {
    final target = File('${directory.path}${Platform.pathSeparator}active.bin');
    final controller = StreamController<List<int>>();
    final downloader = ResumableMediaDownloader(
      clientFactory: () => MockClient.streaming((request, body) async {
        return http.StreamedResponse(
          controller.stream,
          HttpStatus.ok,
          contentLength: 4,
        );
      }),
    );

    final future = downloader.download(
      resolveUrl: () async => Uri.parse('https://storage.invalid/active.bin'),
      destinationPath: target.path,
      expectedBytes: 4,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(MediaCacheLeaseRegistry.shared.isLeased(target.path), isTrue);
    expect(MediaCacheLeaseRegistry.shared.isLeased('${target.path}.part'), isTrue);

    controller.add(<int>[1, 2, 3, 4]);
    await controller.close();
    await future;

    expect(MediaCacheLeaseRegistry.shared.isLeased(target.path), isFalse);
    expect(MediaCacheLeaseRegistry.shared.isLeased('${target.path}.part'), isFalse);
  });

  test('network failure keeps partial data for a later retry', () async {
    final target = File('${directory.path}${Platform.pathSeparator}retry.bin');
    final part = File('${target.path}.part');
    await part.writeAsBytes(<int>[1, 2, 3, 4]);
    final downloader = ResumableMediaDownloader(
      clientFactory: () => MockClient((request) async {
        return http.Response('temporary', HttpStatus.serviceUnavailable);
      }),
    );

    await expectLater(
      downloader.download(
        resolveUrl: () async => Uri.parse('https://storage.invalid/retry.bin'),
        destinationPath: target.path,
        expectedBytes: 10,
        maximumAttempts: 1,
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await part.readAsBytes(), <int>[1, 2, 3, 4]);
  });
}
