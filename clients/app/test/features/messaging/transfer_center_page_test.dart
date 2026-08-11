import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/media_cache_manager.dart';
import 'package:im_client/features/messaging/application/media_transfer_controller.dart';
import 'package:im_client/features/messaging/domain/media_transfer_state.dart';
import 'package:im_client/features/messaging/presentation/transfer_center_page.dart';

void main() {
  testWidgets('transfer center shows active task and can pause it', (tester) async {
    final controller = MediaTransferController(maxConcurrent: 1);
    addTearDown(controller.dispose);
    controller.enqueue(
      id: 'upload-1',
      kind: MediaTransferKind.video,
      direction: MediaTransferDirection.upload,
      label: 'movie.mp4',
      operation: (task) async {
        task.update(
          const MediaTransferState(
            phase: MediaTransferPhase.uploading,
            transferredBytes: 25,
            totalBytes: 100,
          ),
        );
        while (!task.isCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        throw const MediaTransferAborted();
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: TransferCenterPage(
          controller: controller,
          cacheManager: _FakeCache(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('movie.mp4'), findsOneWidget);
    expect(find.textContaining('上传中'), findsOneWidget);
    expect(find.byKey(const Key('pause-transfer-upload-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('pause-transfer-upload-1')));
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.task('upload-1')?.state.phase, MediaTransferPhase.paused);
    expect(find.textContaining('已暂停'), findsWidgets);
    expect(find.byKey(const Key('resume-transfer-upload-1')), findsOneWidget);
  });

  testWidgets('completed download exposes open save share actions', (tester) async {
    final controller = MediaTransferController(maxConcurrent: 1);
    addTearDown(controller.dispose);
    var opened = 0;
    var saved = 0;
    var shared = 0;
    controller.enqueue(
      id: 'download-1',
      kind: MediaTransferKind.file,
      direction: MediaTransferDirection.download,
      label: 'report.pdf',
      openAction: () async => opened++,
      saveAction: () async => saved++,
      shareAction: () async => shared++,
      operation: (task) async {
        task.update(
          const MediaTransferState(
            phase: MediaTransferPhase.uploading,
            transferredBytes: 100,
            totalBytes: 100,
          ),
        );
      },
    );
    await controller.waitForIdle();

    await tester.pumpWidget(
      MaterialApp(
        home: TransferCenterPage(
          controller: controller,
          cacheManager: _FakeCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('打开'));
    await tester.pump();
    await tester.tap(find.byTooltip('另存'));
    await tester.pump();
    await tester.tap(find.byTooltip('分享'));
    await tester.pump();
    expect((opened, saved, shared), (1, 1, 1));
  });
}

final class _FakeCache implements MediaCacheGateway {
  @override
  Future<void> clear(MediaCacheKind kind) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> prune() async {}

  @override
  Future<MediaCacheSummary> snapshot() async => MediaCacheSummary(
    <MediaCacheKind, int>{
      MediaCacheKind.file: 8 * 1024 * 1024,
    },
  );
}
